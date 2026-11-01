//
//  ListingPhotoLinksTests.swift
//  freebnbTests
//
//  Signed listing-photo links: one callable per listing however many photos ask, refresh before expiry, a
//  bounded refetch for a reference the batch doesn't carry, and nothing carried across a sign-out.
//

import Foundation
import Testing
@testable import freebnb

/// Counts calls and answers with whatever `respond` returns for the listing.
private actor FakeLinkFetcher: ListingPhotoLinkFetching {
    private(set) var calls: [String] = []
    private var respond: @Sendable (String, Int) throws -> ListingPhotoLinkBatch

    init(respond: @escaping @Sendable (String, Int) throws -> ListingPhotoLinkBatch) {
        self.respond = respond
    }

    func fetchLinks(homeID: String) async throws -> ListingPhotoLinkBatch {
        calls.append(homeID)
        // Yield so concurrent callers pile up on the in-flight call.
        await Task.yield()
        return try respond(homeID, calls.count)
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private let cover = "gs://bucket/listings/host/home-1/cover.jpg"
private let second = "gs://bucket/listings/host/home-1/second.jpg"

private func signed(_ name: String, call: Int) -> URL {
    var components = URLComponents(string: "https://storage.googleapis.com/bucket")
    components?.path += "/\(name)"
    components?.queryItems = [URLQueryItem(name: "sig", value: "\(call)")]
    return components?.url ?? URL(fileURLWithPath: "/unreachable")
}

@MainActor
struct ListingPhotoLinksTests {
    let clock = Clock()

    private func links(_ fetcher: FakeLinkFetcher) -> ListingPhotoLinks {
        let clock = clock
        return ListingPhotoLinks(fetcher: fetcher, now: { clock.now })
    }

    private func fetcher(ttl: TimeInterval = 3600, refs: [String] = [cover, second]) -> FakeLinkFetcher {
        let start = clock.now
        return FakeLinkFetcher { _, call in
            ListingPhotoLinkBatch(
                urls: Dictionary(uniqueKeysWithValues: refs.map { ref in
                    (ref, signed((ref as NSString).lastPathComponent, call: call))
                }),
                expiresAt: start.addingTimeInterval(ttl)
            )
        }
    }

    @Test func everyPhotoOfAListingSharesOneCall() async throws {
        let fake = fetcher()
        let links = links(fake)
        async let a = links.url(for: cover, homeID: "home-1")
        async let b = links.url(for: second, homeID: "home-1")
        let (first, other) = try await (a, b)
        #expect(first == signed("cover.jpg", call: 1))
        #expect(other == signed("second.jpg", call: 1))
        _ = try await links.url(for: cover, homeID: "home-1")
        #expect(await fake.calls == ["home-1"])
    }

    @Test func refreshesALinkCloseToExpiry() async throws {
        let fake = fetcher(ttl: 3600)
        let links = links(fake)
        _ = try await links.url(for: cover, homeID: "home-1")
        clock.now = clock.now.addingTimeInterval(3600 - ListingPhotoLinks.refreshMargin + 1)
        _ = try await links.url(for: cover, homeID: "home-1")
        #expect(await fake.calls.count == 2)
    }

    @Test func aMissingReferenceRefetchesAtMostOncePerInterval() async throws {
        let fake = fetcher(refs: [cover])
        let links = links(fake)
        _ = try await links.url(for: cover, homeID: "home-1")
        await #expect(throws: ListingPhotoLinkError.unavailable) { try await links.url(for: second, homeID: "home-1") }
        #expect(await fake.calls.count == 1)
        clock.now = clock.now.addingTimeInterval(ListingPhotoLinks.missingRefetchInterval)
        await #expect(throws: ListingPhotoLinkError.unavailable) { try await links.url(for: second, homeID: "home-1") }
        #expect(await fake.calls.count == 2)
    }

    @Test func invalidateAndResetDropCachedLinks() async throws {
        let fake = fetcher()
        let links = links(fake)
        _ = try await links.url(for: cover, homeID: "home-1")
        links.invalidate(homeID: "home-1")
        _ = try await links.url(for: cover, homeID: "home-1")
        links.reset()
        _ = try await links.url(for: cover, homeID: "home-1")
        #expect(await fake.calls.count == 3)
    }

    @Test func aDeniedListingSurfacesTheError() async {
        struct Denied: Error {}
        let links = links(FakeLinkFetcher { _, _ in throw Denied() })
        await #expect(throws: Denied.self) { try await links.url(for: cover, homeID: "home-1") }
    }

    @Test func nonStorageImagesPassThroughWithoutACall() async throws {
        let fake = fetcher()
        let links = links(fake)
        let url = try await links.url(for: "https://example.com/cover.jpg", homeID: "home-1")
        #expect(url.absoluteString == "https://example.com/cover.jpg")
        #expect(await fake.calls.isEmpty)
    }

    @Test func parsesTheCallableAnswer() {
        let batch = FirebaseListingPhotoLinkFetcher.parse([
            "urls": [cover: "https://storage.googleapis.com/bucket/cover.jpg?sig=1"],
            "expiresAt": NSNumber(value: 1_700_000_000_000.0),
        ])
        #expect(batch.urls[cover]?.absoluteString == "https://storage.googleapis.com/bucket/cover.jpg?sig=1")
        #expect(batch.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(FirebaseListingPhotoLinkFetcher.parse("garbage").urls.isEmpty)
    }
}

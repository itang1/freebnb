//
//  ListingPhotoLinks.swift
//  freebnb
//
//  Turns a listing's stored photo references into URLs the app can load. storage.rules denies every client
//  read, so a photo is only reachable through the `listingPhotoURLs` callable, which checks the caller against
//  the listing's audience (the same check as the `homes` read rule) and returns short-lived signed URLs.
//

@preconcurrency import FirebaseFunctions
import Foundation

/// One callable answer: signed URLs keyed by the stored reference they stand for, valid until `expiresAt`.
struct ListingPhotoLinkBatch: Sendable, Equatable {
    var urls: [String: URL]
    var expiresAt: Date
}

protocol ListingPhotoLinkFetching: Sendable {
    func fetchLinks(homeID: String) async throws -> ListingPhotoLinkBatch
}

enum ListingPhotoLinkError: LocalizedError, Equatable {
    case notConfigured
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Listing photos aren't set up."
        case .unavailable: return "This photo isn't available."
        }
    }
}

/// Default stand-in so tests and previews never call Cloud Functions.
struct NoopListingPhotoLinkFetcher: ListingPhotoLinkFetching {
    func fetchLinks(homeID: String) async throws -> ListingPhotoLinkBatch {
        throw ListingPhotoLinkError.notConfigured
    }
}

struct FirebaseListingPhotoLinkFetcher: ListingPhotoLinkFetching {
    private let functions: Functions

    init(functions: Functions = .functions()) {
        self.functions = functions
    }

    func fetchLinks(homeID: String) async throws -> ListingPhotoLinkBatch {
        let result = try await functions.httpsCallable("listingPhotoURLs").call(["homeID": homeID])
        return Self.parse(result.data)
    }

    /// Decodes `{ urls: { [ref]: url }, expiresAt: epochMillis }`. Unparseable entries are dropped, so the
    /// photos behind them fall back to their placeholder rather than failing the whole listing.
    static func parse(_ data: Any) -> ListingPhotoLinkBatch {
        let payload = data as? [String: Any] ?? [:]
        let raw = payload["urls"] as? [String: String] ?? [:]
        let urls = raw.compactMapValues { URL(string: $0) }
        let millis = (payload["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return ListingPhotoLinkBatch(urls: urls, expiresAt: Date(timeIntervalSince1970: millis / 1000))
    }
}

/// Caches one batch of signed URLs per listing and shares a single in-flight call between every image of
/// that listing on screen, so a feed of ten cards makes ten calls, not one per photo.
@MainActor
final class ListingPhotoLinks {
    /// The app's instance, configured with the Firebase fetcher at launch (see `FreeBNBApp`).
    static let shared = ListingPhotoLinks()

    /// A link is refreshed once it has less than this left, so an image never starts loading on a URL that
    /// expires mid-download.
    static let refreshMargin: TimeInterval = 5 * 60
    /// A reference missing from a batch triggers one refetch (the listing may have gained a photo since), but
    /// not more often than this, so a reference the server won't sign can't turn into a request loop.
    static let missingRefetchInterval: TimeInterval = 30

    var fetcher: ListingPhotoLinkFetching
    private let now: @MainActor () -> Date
    private var batches: [String: (batch: ListingPhotoLinkBatch, fetchedAt: Date)] = [:]
    private var inFlight: [String: Task<ListingPhotoLinkBatch, Error>] = [:]
    /// Bumped by `reset()` so a call that was in flight across a sign-out can't cache its answer.
    private var generation = 0

    init(fetcher: ListingPhotoLinkFetching = NoopListingPhotoLinkFetcher(), now: @escaping @MainActor () -> Date = Date.init) {
        self.fetcher = fetcher
        self.now = now
    }

    /// A loadable URL for one stored photo reference. A reference that isn't a Storage object (a plain https
    /// image, as seed data may carry) is returned as is.
    func url(for reference: String, homeID: String) async throws -> URL {
        guard let parsed = URL(string: reference) else { throw ListingPhotoLinkError.unavailable }
        guard ListingPhotoPath.objectPath(fromStoredReference: parsed) != nil else { return parsed }

        if let cached = batches[homeID], isFresh(cached.batch) {
            if let url = cached.batch.urls[reference] { return url }
            guard now().timeIntervalSince(cached.fetchedAt) >= Self.missingRefetchInterval else {
                throw ListingPhotoLinkError.unavailable
            }
        }
        let batch = try await fetch(homeID: homeID)
        guard let url = batch.urls[reference] else { throw ListingPhotoLinkError.unavailable }
        return url
    }

    /// Drops the cached links for a listing, e.g. after its photos changed or the viewer lost access.
    func invalidate(homeID: String) {
        batches[homeID] = nil
    }

    /// Drops everything; called on sign-out so the next account never sees links signed for the last one.
    func reset() {
        generation += 1
        batches.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func isFresh(_ batch: ListingPhotoLinkBatch) -> Bool {
        batch.expiresAt.timeIntervalSince(now()) > Self.refreshMargin
    }

    private func fetch(homeID: String) async throws -> ListingPhotoLinkBatch {
        if let task = inFlight[homeID] { return try await task.value }
        let fetcher = fetcher
        let task = Task { try await fetcher.fetchLinks(homeID: homeID) }
        let started = generation
        inFlight[homeID] = task
        defer { if inFlight[homeID] == task { inFlight[homeID] = nil } }
        let batch = try await task.value
        if generation == started { batches[homeID] = (batch, now()) }
        return batch
    }
}

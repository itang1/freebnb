//
//  freebnbTests.swift
//  freebnbTests
//
//  Firebase-free tests exercising the repository seam (via the in-memory
//  doubles) and pure model logic. The @MainActor stores talk to Auth.auth()
//  in their initializers, so they need a configured Firebase app and are not
//  unit-testable here; the repository protocols and models are.
//

import Foundation
import Testing
@testable import freebnb

// MARK: - Fixtures

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 86_400 * Double(n)) }

/// Captures the latest value delivered to a synchronous handler-based listener.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func makeAmenities() -> Amenities {
    Amenities(
        hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
        hasMicrowave: false, hasTV: false, hasWifi: false,
        hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
        hasInUnitLaundry: false, hasCoinLaundryNearby: false,
        providesPillows: false, providesBlankets: false, providesTowels: false,
        providesToiletries: false, foodProvision: .none
    )
}

private func makeHome(
    id: String = UUID().uuidString,
    hostUserID: String,
    hostName: String = "Host",
    deletedAt: Date? = nil,
    visibility: ListingVisibility? = nil,
    allowedViewerIDs: [String]? = nil,
    createdAt: Date? = nil
) -> Home {
    Home(
        hostUserID: hostUserID,
        hostName: hostName,
        address: Address(city: "Town", state: "CA", zip: "00000"),
        description: nil,
        contactPreference: .inApp,
        hostContactInfo: nil,
        hostMotivation: .open,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
        amenities: makeAmenities()
    )
    .with(id: id, deletedAt: deletedAt, visibility: visibility, allowedViewerIDs: allowedViewerIDs, createdAt: createdAt)
}

private extension Home {
    func with(
        id: String,
        deletedAt: Date?,
        visibility: ListingVisibility?,
        allowedViewerIDs: [String]?,
        createdAt: Date? = nil
    ) -> Home {
        var copy = self
        copy.id = id
        copy.deletedAt = deletedAt
        copy.visibility = visibility
        copy.allowedViewerIDs = allowedViewerIDs
        copy.createdAt = createdAt
        return copy
    }
}

// Recency-ordered timestamps for feed tests: `t("a")` is newest, `t("e")` older,
// so a listing set given createdAt = t(id) sorts alphabetically by id (which is
// also how the pre-recency tests read).
private func t(_ id: String) -> Date {
    Date(timeIntervalSince1970: 100_000 - Double(id.unicodeScalars.first!.value))
}

private func makeRequest(
    id: String,
    listingID: String = "L",
    host: String = "host",
    guest: String = "guest",
    checkIn: Date,
    checkOut: Date,
    status: StayRequestStatus = .pending
) -> StayRequest {
    StayRequest(
        id: id,
        listingID: listingID,
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: host,
        guestUserID: guest,
        checkIn: checkIn,
        checkOut: checkOut,
        status: status
    )
}

// MARK: - Stay requests: double-booking guard (H2)

struct StayRequestRepositoryTests {
    @Test func acceptRejectsOverlappingAcceptedStay() async throws {
        let repo = InMemoryStayRequestsRepository()
        let existing = makeRequest(id: "r1", checkIn: day(1), checkOut: day(5), status: .accepted)
        let incoming = makeRequest(id: "r2", checkIn: day(3), checkOut: day(7))
        try await repo.create(existing)
        try await repo.create(incoming)

        await #expect(throws: StayRequestError.self) {
            try await repo.accept(incoming, hostNote: nil)
        }
    }

    @Test func acceptAllowsAdjacentStay() async throws {
        // Half-open intervals: a checkout on the same day as the next checkin
        // does not overlap.
        let repo = InMemoryStayRequestsRepository()
        let existing = makeRequest(id: "r1", checkIn: day(1), checkOut: day(5), status: .accepted)
        let incoming = makeRequest(id: "r2", checkIn: day(5), checkOut: day(9))
        try await repo.create(existing)
        try await repo.create(incoming)

        try await repo.accept(incoming, hostNote: "welcome")

        let box = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "host", role: .host) { result in
            if case .success(let requests) = result { box.value = requests }
        }
        let accepted = box.value.first { $0.id == "r2" }
        #expect(accepted?.status == .accepted)
        #expect(accepted?.hostNote == "welcome")
    }

    @Test func acceptIgnoresDeclinedConflicts() async throws {
        let repo = InMemoryStayRequestsRepository()
        let declined = makeRequest(id: "r1", checkIn: day(1), checkOut: day(9), status: .declined)
        let incoming = makeRequest(id: "r2", checkIn: day(2), checkOut: day(4))
        try await repo.create(declined)
        try await repo.create(incoming)

        try await repo.accept(incoming, hostNote: nil)  // must not throw
    }

    // The `homes/{id}/accepted/{guestUserID}` marker is the whole capability: its
    // existence is what firestore.rules checks before handing over the street
    // address. These pin the two transitions that write and clear it.

    @Test func acceptingDisclosesTheAddressToTheGuest() async throws {
        let repo = InMemoryStayRequestsRepository()
        let request = makeRequest(id: "r1", checkIn: day(1), checkOut: day(3))
        try await repo.create(request)
        #expect(!repo.hasAddressAccess(listingID: request.listingID, guestUserID: request.guestUserID))

        try await repo.accept(request, hostNote: nil)
        #expect(repo.hasAddressAccess(listingID: request.listingID, guestUserID: request.guestUserID))
    }

    @Test func cancellingAnAcceptedStayRevokesTheAddress() async throws {
        let repo = InMemoryStayRequestsRepository()
        let request = makeRequest(id: "r1", checkIn: day(1), checkOut: day(3))
        try await repo.create(request)
        try await repo.accept(request, hostNote: nil)

        try await repo.updateStatus(request, status: .cancelled, hostNote: nil)
        #expect(!repo.hasAddressAccess(listingID: request.listingID, guestUserID: request.guestUserID))
    }

    @Test func decliningNeverDisclosesTheAddress() async throws {
        let repo = InMemoryStayRequestsRepository()
        let request = makeRequest(id: "r1", checkIn: day(1), checkOut: day(3))
        try await repo.create(request)

        try await repo.updateStatus(request, status: .declined, hostNote: "Sorry!")
        #expect(!repo.hasAddressAccess(listingID: request.listingID, guestUserID: request.guestUserID))
    }
}

// MARK: - Public coordinate blurring

struct ApproximateCoordinateTests {
    /// The public coordinate must not resolve to a building. Two decimal places is
    /// on the order of a kilometre, which is the promise HomeDetailPage's circle makes.
    @Test func approximateRoundsToTwoDecimalPlaces() {
        #expect(Home.approximate(37.33182) == 37.33)
        #expect(Home.approximate(-122.03118) == -122.03)
        #expect(Home.approximate(0) == 0)
    }

    @Test func approximateDiscardsAtLeastTenMetresOfPrecision() {
        // 0.0001 degrees is roughly 11 m; rounding must move a coordinate that far
        // off the exact point for any value not already on the grid.
        let exact = 42.36159
        #expect(abs(Home.approximate(exact) - exact) > 0.0001)
    }
}

// MARK: - Homes

struct HomesRepositoryTests {
    @Test func ownListingsExcludeSoftDeleted() async throws {
        let live = makeHome(id: "a", hostUserID: "me")
        let gone = makeHome(id: "b", hostUserID: "me", deletedAt: Date())
        let repo = InMemoryHomesRepository(homes: [live, gone])

        let box = Box<[Home]>([])
        _ = repo.listenToOwnListings(hostUserID: "me") { result in
            if case .success(let homes) = result { box.value = homes }
        }
        #expect(box.value.map(\.id) == ["a"])
    }

    @Test func updateHostNameRenamesEveryListing() async throws {
        let repo = InMemoryHomesRepository(homes: [
            makeHome(id: "a", hostUserID: "me", hostName: "Old"),
            makeHome(id: "b", hostUserID: "me", hostName: "Old")
        ])
        try await repo.updateHostName(userID: "me", newName: "New")

        let box = Box<[Home]>([])
        _ = repo.listenToOwnListings(hostUserID: "me") { result in
            if case .success(let homes) = result { box.value = homes }
        }
        #expect(box.value.allSatisfy { $0.hostName == "New" })
    }

    // The repository — not the view layer — is now the visibility boundary, so
    // these assert on what a viewer can even fetch. They mirror the two clauses
    // of the `homes` read rule in firestore.rules; if one drifts, so must the other.

    // createdAt = t(id) so the recency order (newest first) is a, b, c, d, e —
    // i.e. the visibility and paging assertions below read in id order.
    private static let friendsOnlyFeed = [
        makeHome(id: "a", hostUserID: "stranger", visibility: .friendsOnly, allowedViewerIDs: ["stranger"], createdAt: t("a")),
        makeHome(id: "b", hostUserID: "friend", visibility: .friendsOnly, allowedViewerIDs: ["friend", "me"], createdAt: t("b")),
        makeHome(id: "c", hostUserID: "me", visibility: .friendsOnly, allowedViewerIDs: ["me"], createdAt: t("c")),
        makeHome(id: "d", hostUserID: "stranger", visibility: .everyone, allowedViewerIDs: ["stranger"], createdAt: t("d")),
        makeHome(id: "e", hostUserID: "stranger", visibility: nil, allowedViewerIDs: nil, createdAt: t("e"))
    ]

    @Test func feedHidesFriendsOnlyListingsFromNonViewers() async throws {
        let repo = InMemoryHomesRepository(homes: Self.friendsOnlyFeed)
        let visible = try await repo.fetchVisibleListings(viewerID: "me", after: nil, limit: 10)
        // "a" is friends-only and doesn't name "me"; "e" is legacy, so it reads as everyone.
        #expect(visible.map(\.id) == ["b", "c", "d", "e"])
    }

    @Test func anonymousViewerSeesOnlyPublicListings() async throws {
        let repo = InMemoryHomesRepository(homes: Self.friendsOnlyFeed)
        let visible = try await repo.fetchVisibleListings(viewerID: "", after: nil, limit: 10)
        #expect(visible.map(\.id) == ["d", "e"])
    }

    @Test func pagingSkipsListingsTheViewerCannotSee() async throws {
        let repo = InMemoryHomesRepository(homes: Self.friendsOnlyFeed)
        let cursor = ListingCursor(createdAt: t("b"), id: "b")
        let page = try await repo.fetchVisibleListings(viewerID: "me", after: cursor, limit: 2)
        #expect(page.map(\.id) == ["c", "d"])
    }
}

// MARK: - Feed page merging

struct MergeVisibleListingsTests {
    /// The two partitioned queries overlap on nothing in principle, but a listing
    /// that is both `everyone` and names the viewer arrives twice. Recency order
    /// (newest first) makes the merge deterministic and the de-duplication stable.
    @Test func mergeDeduplicatesAndOrdersByRecency() {
        let overlap = makeHome(id: "b", hostUserID: "friend", visibility: .everyone, allowedViewerIDs: ["friend", "me"], createdAt: t("b"))
        let merged = mergeVisibleListings([
            makeHome(id: "c", hostUserID: "x", visibility: .everyone, createdAt: t("c")),
            overlap,
            makeHome(id: "a", hostUserID: "y", visibility: .everyone, createdAt: t("a")),
            overlap
        ], limit: 10)
        // t("a") is newest, so a sorts first, then b, then c.
        #expect(merged.map(\.id) == ["a", "b", "c"])
    }

    /// Each half is fetched with the caller's page size, so the merge holds up to
    /// twice that. Truncating after the sort is what makes the result the true
    /// globally-first page rather than the first page of one partition.
    @Test func mergeTruncatesToLimitAfterOrdering() {
        let merged = mergeVisibleListings([
            makeHome(id: "d", hostUserID: "x", createdAt: t("d")),
            makeHome(id: "a", hostUserID: "x", createdAt: t("a")),
            makeHome(id: "c", hostUserID: "x", createdAt: t("c")),
            makeHome(id: "b", hostUserID: "x", createdAt: t("b"))
        ], limit: 2)
        // Newest two: a then b.
        #expect(merged.map(\.id) == ["a", "b"])
    }
}

// MARK: - User profiles

struct UserProfileRepositoryTests {
    @Test func createThenFetchRoundTrips() async throws {
        let repo = InMemoryUserProfileRepository()
        try await repo.createInitialProfile(userID: "u1", displayName: "Ada", email: "ada@example.com")
        let fetched = try await repo.fetchProfile(userID: "u1")
        #expect(fetched?.displayName == "Ada")
    }

    @Test func savedListingsUpdate() async throws {
        let repo = InMemoryUserProfileRepository()
        try await repo.createInitialProfile(userID: "u1", displayName: "Ada", email: nil)
        try await repo.updateSavedListings(userID: "u1", listingIDs: ["L1", "L2"])
        let fetched = try await repo.fetchProfile(userID: "u1")
        #expect(fetched?.savedIDs == ["L1", "L2"])
    }

    @Test func searchMatchesDisplayNamePrefix() async throws {
        let repo = InMemoryUserProfileRepository()
        try await repo.createInitialProfile(userID: "u1", displayName: "Ada", email: nil)
        try await repo.createInitialProfile(userID: "u2", displayName: "Alan", email: nil)
        try await repo.createInitialProfile(userID: "u3", displayName: "Grace", email: nil)

        let results = try await repo.searchProfiles(query: "A")
        #expect(Set(results.map(\.displayName)) == ["Ada", "Alan"])
    }
}

// MARK: - Friend edges

struct FriendEdgeRepositoryTests {
    @Test func createAcceptDeleteLifecycle() async throws {
        let repo = InMemoryFriendEdgeRepository()
        let pair = ["alice", "bob"].sorted()
        let edge = FriendEdge(userA: pair[0], userB: pair[1], status: .pending, initiator: "alice")
        try await repo.createEdge(edge)

        let id = FriendEdge.edgeID("alice", "bob")
        try await repo.updateStatus(edgeID: id, status: .accepted)

        let box = Box<[FriendEdge]>([])
        _ = repo.listenToEdges(userID: pair[0], field: "userA") { result in
            if case .success(let edges) = result { box.value = edges }
        }
        #expect(box.value.first?.status == .accepted)

        try await repo.deleteEdge(edgeID: id)
        let box2 = Box<[FriendEdge]>([])
        _ = repo.listenToEdges(userID: pair[0], field: "userA") { result in
            if case .success(let edges) = result { box2.value = edges }
        }
        #expect(box2.value.isEmpty)
    }
}

// MARK: - Pure model logic

struct ModelLogicTests {
    @Test func conversationIDIsCanonicalRegardlessOfOrder() {
        let a = MessageStore.conversationID(userIDs: ["bob", "alice"])
        let b = MessageStore.conversationID(userIDs: ["alice", "bob"])
        #expect(a == b)
        #expect(a == "alice_bob")
    }

    @Test func dateRangeOverlapIsHalfOpen() {
        let range = DateRange(start: day(1), end: day(5))
        #expect(range.overlaps(checkIn: day(3), checkOut: day(6)))   // straddles
        #expect(!range.overlaps(checkIn: day(5), checkOut: day(8)))  // starts at end
        #expect(!range.overlaps(checkIn: day(6), checkOut: day(9)))  // fully after
    }

    @Test func nightsCountsCalendarDays() {
        let request = makeRequest(id: "r", checkIn: day(2), checkOut: day(5))
        #expect(request.nights == 3)
    }
}

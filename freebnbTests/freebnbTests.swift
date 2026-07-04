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
    deletedAt: Date? = nil
) -> Home {
    Home(
        hostUserID: hostUserID,
        hostName: hostName,
        address: Address(street: "1 Main", city: "Town", state: "CA", zip: "00000"),
        description: nil,
        contactPreference: .inApp,
        hostContactInfo: nil,
        hostMotivation: .open,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
        amenities: makeAmenities()
    )
    .with(id: id, deletedAt: deletedAt)
}

private extension Home {
    func with(id: String, deletedAt: Date?) -> Home {
        var copy = self
        copy.id = id
        copy.deletedAt = deletedAt
        return copy
    }
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

//
//  StoreTests.swift
//  freebnbTests
//
//  Exercises the @MainActor stores themselves (not just the repository seam
//  covered in freebnbTests.swift), by injecting the in-memory repository
//  doubles from InMemoryRepositories.swift instead of the Firestore-backed
//  defaults. This target is hosted by the freebnb app (TEST_HOST), so by the
//  time these tests run, FreeBNBApp.init() has already called
//  FirebaseApp.configure() — Auth.auth() is safe to touch here without extra
//  setup. Every store method under test writes only through its injected
//  repository, so nothing here reaches Firestore or production data.
//

import Foundation
import Testing
@testable import freebnb

/// Captures the latest value delivered to a synchronous handler-based listener.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 86_400 * Double(n)) }

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

private func makeHome(id: String = UUID().uuidString, hostUserID: String) -> Home {
    var home = Home(
        hostUserID: hostUserID,
        hostName: "Host",
        address: Address(street: "1 Main", city: "Town", state: "CA", zip: "00000"),
        description: nil,
        contactPreference: .inApp,
        hostContactInfo: nil,
        hostMotivation: .open,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
        amenities: makeAmenities()
    )
    home.id = id
    return home
}

@MainActor
struct HomeStoreTests {
    @Test func saveAddsListingToRepository() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = makeHome(hostUserID: "host1")

        try await store.save(home)

        let saved = try await repo.fetchVisibleListings(viewerID: "host1", afterID: nil, limit: 10)
        #expect(saved.map(\.id) == [home.id])
    }
}

@MainActor
struct StayRequestStoreTests {
    @Test func sendCreatesPendingRequest() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = makeHome(id: "L1", hostUserID: "host1")

        try await store.send(listing: listing, guestUserID: "guest1", checkIn: day(1), checkOut: day(3), guestNote: "hi")

        let box = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "guest1", role: .guest) { result in
            if case .success(let requests) = result { box.value = requests }
        }
        #expect(box.value.count == 1)
        #expect(box.value.first?.status == .pending)
    }

    @Test func acceptThenDeclineUpdatesStatus() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = makeHome(id: "L1", hostUserID: "host1")
        try await store.send(listing: listing, guestUserID: "guest1", checkIn: day(1), checkOut: day(3), guestNote: nil)

        let box = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "host1", role: .host) { result in
            if case .success(let requests) = result { box.value = requests }
        }
        let request = try #require(box.value.first)

        try await store.accept(request, hostNote: "welcome")
        let boxAfterAccept = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "host1", role: .host) { result in
            if case .success(let requests) = result { boxAfterAccept.value = requests }
        }
        #expect(boxAfterAccept.value.first?.status == .accepted)

        try await store.decline(boxAfterAccept.value[0])
        let boxAfterDecline = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "host1", role: .host) { result in
            if case .success(let requests) = result { boxAfterDecline.value = requests }
        }
        #expect(boxAfterDecline.value.first?.status == .declined)
    }
}

@MainActor
struct FriendStoreTests {
    // sendRequest reads Auth.auth().currentUser for the initiator, which this
    // test host doesn't control deterministically, so accept/decline (which
    // only need an existing edge) are exercised instead.
    @Test func acceptThenDeclineUpdatesEdgeViaRepository() async throws {
        let repo = InMemoryFriendEdgeRepository()
        let store = FriendStore(repository: repo)
        try await repo.createEdge(FriendEdge(userA: "alice", userB: "bob", status: .pending, initiator: "alice"))

        let box = Box<[FriendEdge]>([])
        _ = repo.listenToEdges(userID: "alice", field: "userA") { result in
            if case .success(let edges) = result { box.value = edges }
        }
        let edge = try #require(box.value.first)

        try await store.accept(edge)
        let boxAfterAccept = Box<[FriendEdge]>([])
        _ = repo.listenToEdges(userID: "alice", field: "userA") { result in
            if case .success(let edges) = result { boxAfterAccept.value = edges }
        }
        #expect(boxAfterAccept.value.first?.status == .accepted)

        try await store.decline(boxAfterAccept.value[0])
        let boxAfterDecline = Box<[FriendEdge]>([])
        _ = repo.listenToEdges(userID: "alice", field: "userA") { result in
            if case .success(let edges) = result { boxAfterDecline.value = edges }
        }
        #expect(boxAfterDecline.value.isEmpty)
    }
}

@MainActor
struct UserProfileStoreTests {
    // updateDisplayName also requires a signed-in Auth user before it ever
    // touches the repository; only the validation that runs before that guard
    // is deterministic in this environment.
    @Test func updateDisplayNameRejectsBlankName() async throws {
        let repo = InMemoryUserProfileRepository()
        let store = UserProfileStore(repository: repo)

        await #expect(throws: UserProfileStore.ProfileUpdateError.self) {
            try await store.updateDisplayName("   ")
        }
    }
}

@MainActor
struct MessageStoreTests {
    @Test func sendAppendsMessageToRepository() throws {
        let repo = InMemoryMessagesRepository()
        let store = MessageStore(repository: repo)

        let sent = store.send(text: "hello", senderUserID: "alice", recipientUserID: "bob")
        #expect(sent)

        let box = Box<[(messages: [Message], hasMore: Bool)]>([])
        _ = repo.listenToConversation(participants: ["alice", "bob"], limit: 10) { result in
            if case .success(let page) = result { box.value.append(page) }
        }
        #expect(box.value.first?.messages.map(\.text) == ["hello"])
    }

    @Test func sendRejectsMessageToSelf() throws {
        let repo = InMemoryMessagesRepository()
        let store = MessageStore(repository: repo)

        let sent = store.send(text: "hello", senderUserID: "alice", recipientUserID: "alice")
        #expect(!sent)
    }
}

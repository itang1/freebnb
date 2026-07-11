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

import FirebaseFirestore
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
        address: Address(city: "Town", state: "CA", zip: "00000"),
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

        let saved = try await repo.fetchVisibleListings(viewerID: "host1", after: nil, limit: 10)
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

    @Test func modifyDatesRewritesTheStayInPlace() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = makeHome(id: "L1", hostUserID: "host1")
        try await store.send(listing: listing, guestUserID: "guest1", checkIn: day(1), checkOut: day(3), guestNote: nil)

        let box = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "guest1", role: .guest) { result in
            if case .success(let requests) = result { box.value = requests }
        }
        let request = try #require(box.value.first)

        try await store.modifyDates(request, checkIn: day(5), checkOut: day(9))

        let after = Box<[StayRequest]>([])
        _ = repo.listenToRequests(userID: "guest1", role: .guest) { result in
            if case .success(let requests) = result { after.value = requests }
        }
        let updated = try #require(after.value.first)
        #expect(updated.checkIn == day(5))
        #expect(updated.checkOut == day(9))
        // Still the same pending request, not a cancel-and-resend.
        #expect(updated.id == request.id)
        #expect(updated.status == .pending)
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

    @Test func sendStayEventCarriesEventAndFallbackText() throws {
        let repo = InMemoryMessagesRepository()
        let store = MessageStore(repository: repo)

        let event = StayEvent(kind: .accepted, dateRange: "Mar 3 – Mar 6 · 3 nights", note: "Door code 1988")
        let sent = store.sendStayEvent(event, senderUserID: "alice", recipientUserID: "bob")
        #expect(sent)

        let box = Box<[(messages: [Message], hasMore: Bool)]>([])
        _ = repo.listenToConversation(participants: ["alice", "bob"], limit: 10) { result in
            if case .success(let page) = result { box.value.append(page) }
        }
        let stored = box.value.first?.messages.first
        #expect(stored?.event == event)
        // text stays populated so the list preview / push / older clients still read.
        #expect(stored?.text == "Stay accepted · Mar 3 – Mar 6 · 3 nights\nDoor code 1988")
    }

    @Test func stayEventFallbackTextOmitsEmptyNote() {
        let requested = StayEvent(kind: .requested, dateRange: "Mar 3 – Mar 6 · 3 nights")
        #expect(requested.fallbackText == "Requested to stay · Mar 3 – Mar 6 · 3 nights")
        // An accepted event with no note must not leave a dangling newline.
        let accepted = StayEvent(kind: .accepted, dateRange: "Mar 3 – Mar 6 · 3 nights")
        #expect(accepted.fallbackText == "Stay accepted · Mar 3 – Mar 6 · 3 nights")
    }

    @Test func conversationParsesDocumentWithDefaults() {
        // A summary written before anyone reads or mutes carries no unreadCounts
        // or mutedBy; parsing must still succeed with sensible defaults.
        let ts = Timestamp(date: Date(timeIntervalSince1970: 1_000))
        let conv = Conversation(document: "alice_bob", data: [
            "participants": ["alice", "bob"],
            "lastMessage": ["text": "hi", "senderUserID": "alice", "timestamp": ts],
            "updatedAt": ts,
            "unreadCounts": ["bob": 2],
        ])
        #expect(conv?.participants == ["alice", "bob"])
        #expect(conv?.lastMessage.text == "hi")
        #expect(conv?.lastMessage.senderUserID == "alice")
        #expect(conv?.unreadCounts["bob"] == 2)
        #expect(conv?.unreadCounts["alice"] == nil)
        #expect(conv?.mutedBy == [])
    }

    @Test func conversationRejectsMissingParticipants() {
        #expect(Conversation(document: "x", data: ["lastMessage": ["text": "hi"]]) == nil)
    }

    @Test func conversationListReflectsReadAndMute() {
        let now = Date()
        let messages = [
            Message(senderUserID: "bob", text: "hey", timestamp: now, participants: ["alice", "bob"]),
        ]
        let repo = InMemoryMessagesRepository(messages: messages)

        let box = Box<[Conversation]>([])
        _ = repo.listenToConversations(userID: "alice", limit: 10) { result in
            if case .success(let convs) = result { box.value = convs }
        }
        #expect(box.value.count == 1)

        repo.markConversationRead(conversationID: "alice_bob", userID: "alice") { _ in }
        repo.setConversationMuted(conversationID: "alice_bob", userID: "alice", muted: true) { _ in }

        _ = repo.listenToConversations(userID: "alice", limit: 10) { result in
            if case .success(let convs) = result { box.value = convs }
        }
        #expect(box.value.first?.unreadCounts["alice"] == 0)
        #expect(box.value.first?.mutedBy == ["alice"])
    }
}

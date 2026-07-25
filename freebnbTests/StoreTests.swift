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


@MainActor
struct HomeStoreTests {
    @Test func saveAddsListingToRepository() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        // The ACL names the host, as CreateListingViewModel stamps on every save;
        // the feed read below is a pure "ACL contains me" query with no host
        // fallback, in memory just like in Firestore.
        let home = HomeFixture.make(hostUserID: "host1", allowedViewerIDs: ["host1"])

        try await store.save(home)

        let saved = try await repo.fetchVisibleListings(viewerID: "host1", after: nil, limit: 10)
        #expect(saved.map(\.id) == [home.id])
    }

    /// A friendship made after the listing was saved has to reach the listing's
    /// ACL, or the new friend never sees it. The Cloud Function that did this
    /// isn't deployed, so the client does it.
    @Test func aclRefreshMakesTheListingVisibleToANewFriend() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = HomeFixture.make(hostUserID: "host1", allowedViewerIDs: ["host1"])
        try await store.save(home)
        store.setManagedListingsForTesting([home])

        // Before: the friend is not in the ACL, so the feed query returns nothing.
        var friendSees = try await repo.fetchVisibleListings(viewerID: "friend1", after: nil, limit: 10)
        #expect(friendSees.isEmpty)

        await store.refreshOwnListingACLs(myID: "host1", friendIDs: ["friend1"])

        friendSees = try await repo.fetchVisibleListings(viewerID: "friend1", after: nil, limit: 10)
        #expect(friendSees.map(\.id) == [home.id])
        // The host keeps their own access.
        let hostSees = try await repo.fetchVisibleListings(viewerID: "host1", after: nil, limit: 10)
        #expect(hostSees.map(\.id) == [home.id])
    }

    /// An unfriending has to remove access too, not merely add.
    @Test func aclRefreshDropsAFormerFriend() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = HomeFixture.make(hostUserID: "host1", allowedViewerIDs: ["host1", "friend1"])
        try await store.save(home)
        store.setManagedListingsForTesting([home])

        await store.refreshOwnListingACLs(myID: "host1", friendIDs: [])

        let friendSees = try await repo.fetchVisibleListings(viewerID: "friend1", after: nil, limit: 10)
        #expect(friendSees.isEmpty)
    }

    /// A co-hosted listing is someone else's to publish: the ACL belongs to the
    /// host's friend graph, not to whoever happens to open the app.
    @Test func aclRefreshLeavesCoHostedListingsAlone() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let theirs = HomeFixture.make(hostUserID: "host2", allowedViewerIDs: ["host2"])
        try await store.save(theirs)
        store.setManagedListingsForTesting([theirs])

        await store.refreshOwnListingACLs(myID: "host1", friendIDs: ["friend1"])

        let friendSees = try await repo.fetchVisibleListings(viewerID: "friend1", after: nil, limit: 10)
        #expect(friendSees.isEmpty)
    }

    // MARK: - Booked-range reconciliation

    private func stay(listingID: String, hostUserID: String, inDay: Int, outDay: Int,
                      status: StayRequestStatus = .accepted) -> StayRequest {
        StayRequest(
            listingID: listingID, listingCity: "Town", listingHostName: "Host",
            hostUserID: hostUserID, guestUserID: "guest",
            checkIn: Date(timeIntervalSince1970: 86_400 * Double(inDay)),
            checkOut: Date(timeIntervalSince1970: 86_400 * Double(outDay)),
            status: status
        )
    }

    @Test func reconcileRecordsAcceptedStaysAsBookedAndPublishesTheUnion() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = HomeFixture.make(id: "L1", hostUserID: "host1", allowedViewerIDs: ["host1"])
        try await store.save(home)
        store.setManagedListingsForTesting([home])

        await store.reconcileBookedRanges(
            hostUserID: "host1",
            acceptedStays: [stay(listingID: "L1", hostUserID: "host1", inDay: 3, outDay: 6)]
        )

        let availability = try await repo.fetchAvailability(homeID: "L1")
        #expect(availability.bookedDateRanges.count == 1)
        // The public listing publishes the union guests read.
        let published = try await repo.fetchVisibleListings(viewerID: "host1", after: nil, limit: 10).first
        #expect(published?.unavailableRanges.count == 1)
    }

    @Test func reconcilePreservesBlockedDatesWhenPublishingBookings() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = HomeFixture.make(id: "L1", hostUserID: "host1", allowedViewerIDs: ["host1"])
        try await store.save(home)
        store.setManagedListingsForTesting([home])
        // A host-blocked week already on the calendar.
        try await repo.saveBlockedRanges(homeID: "L1",
            blocked: [DateRange(start: Date(timeIntervalSince1970: 86_400 * 20),
                                end: Date(timeIntervalSince1970: 86_400 * 25))])

        await store.reconcileBookedRanges(
            hostUserID: "host1",
            acceptedStays: [stay(listingID: "L1", hostUserID: "host1", inDay: 3, outDay: 6)]
        )

        let published = try await repo.fetchVisibleListings(viewerID: "host1", after: nil, limit: 10).first
        // Blocked week + booked stay both survive in the published union.
        #expect(published?.unavailableRanges.count == 2)
    }

    @Test func reconcileDropsBookingsForCancelledStays() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let home = HomeFixture.make(id: "L1", hostUserID: "host1", allowedViewerIDs: ["host1"])
        try await store.save(home)
        store.setManagedListingsForTesting([home])
        repo.setBookedRanges(homeID: "L1",
            booked: [DateRange(start: Date(timeIntervalSince1970: 86_400 * 3),
                               end: Date(timeIntervalSince1970: 86_400 * 6))])

        // The stay that produced that booking is now cancelled: it should clear.
        await store.reconcileBookedRanges(
            hostUserID: "host1",
            acceptedStays: [stay(listingID: "L1", hostUserID: "host1", inDay: 3, outDay: 6, status: .cancelled)]
        )

        let availability = try await repo.fetchAvailability(homeID: "L1")
        #expect(availability.bookedDateRanges.isEmpty)
    }

    @Test func reconcileLeavesCoHostedListingsToTheirOwnHost() async throws {
        let repo = InMemoryHomesRepository()
        let store = HomeStore(repository: repo)
        let theirs = HomeFixture.make(id: "L2", hostUserID: "host2", allowedViewerIDs: ["host2"])
        try await store.save(theirs)
        store.setManagedListingsForTesting([theirs])

        await store.reconcileBookedRanges(
            hostUserID: "host1",
            acceptedStays: [stay(listingID: "L2", hostUserID: "host2", inDay: 3, outDay: 6)]
        )

        let availability = try await repo.fetchAvailability(homeID: "L2")
        #expect(availability.bookedDateRanges.isEmpty)
    }

    @Test func normalizedRangesMergesOverlaps() {
        let ranges = [
            DateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100)),
            DateRange(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 200)),
            DateRange(start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 600)),
        ]
        let merged = HomeStore.normalizedRanges(ranges)
        #expect(merged.count == 2)
        #expect(merged.first?.end == Date(timeIntervalSince1970: 200))
    }
}

@MainActor
struct StayRequestStoreTests {
    @Test func sendCreatesPendingRequest() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = HomeFixture.make(id: "L1", hostUserID: "host1")

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
        let listing = HomeFixture.make(id: "L1", hostUserID: "host1")
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

    /// A co-host's inbox is queried by listing, not by party, because a stay
    /// request names only the listing's owner (feature 14). The security boundary
    /// is proven against the emulator in rules-tests/cohosts.test.mjs; this pins
    /// the query contract the client depends on.
    @Test func coHostedListenerReturnsOnlyTheNamedListingsRequests() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let mine = HomeFixture.make(id: "L1", hostUserID: "host1")
        let other = HomeFixture.make(id: "L2", hostUserID: "host2")
        try await store.send(listing: mine, guestUserID: "guest1", checkIn: day(1), checkOut: day(3), guestNote: nil)
        try await store.send(listing: other, guestUserID: "guest2", checkIn: day(1), checkOut: day(3), guestNote: nil)

        let box = Box<[StayRequest]>([])
        _ = repo.listenToCoHostedRequests(listingIDs: ["L1"]) { result in
            if case .success(let requests) = result { box.value = requests }
        }
        #expect(box.value.map(\.listingID) == ["L1"])
    }

    /// An empty roster must not degenerate into "every request": a user who
    /// co-hosts nothing has to get nothing, not an unfiltered query.
    @Test func coHostedListenerWithNoListingsEmitsNothing() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = HomeFixture.make(id: "L1", hostUserID: "host1")
        try await store.send(listing: listing, guestUserID: "guest1", checkIn: day(1), checkOut: day(3), guestNote: nil)

        let box = Box<[StayRequest]>([StayRequest]())
        let sentinel = Box<Bool>(false)
        _ = repo.listenToCoHostedRequests(listingIDs: []) { result in
            sentinel.value = true
            if case .success(let requests) = result { box.value = requests }
        }
        #expect(sentinel.value == false)
        #expect(box.value.isEmpty)
    }

    @Test func modifyDatesRewritesTheStayInPlace() async throws {
        let repo = InMemoryStayRequestsRepository()
        let store = StayRequestStore(repository: repo)
        let listing = HomeFixture.make(id: "L1", hostUserID: "host1")
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

struct StayTimelineTests {
    private func stay(offsetIn: Int, offsetOut: Int, status: StayRequestStatus = .accepted) -> StayRequest {
        let cal = Calendar.current
        let now = Date()
        return StayRequest(
            listingID: "L", listingCity: "C", listingHostName: "H",
            hostUserID: "h", guestUserID: "g",
            checkIn: cal.date(byAdding: .day, value: offsetIn, to: now)!,
            checkOut: cal.date(byAdding: .day, value: offsetOut, to: now)!,
            status: status
        )
    }

    @Test func underwayOnlyWhileTheStayIsHappening() {
        let now = Date()
        #expect(stay(offsetIn: 3, offsetOut: 6).isUnderway(now: now) == false)   // future
        #expect(stay(offsetIn: -1, offsetOut: 2).isUnderway(now: now) == true)   // in progress
        #expect(stay(offsetIn: -5, offsetOut: -2).isUnderway(now: now) == false) // past
    }

    @Test func underwayRequiresAnAcceptedStay() {
        let now = Date()
        #expect(stay(offsetIn: -1, offsetOut: 2, status: .pending).isUnderway(now: now) == false)
        #expect(stay(offsetIn: -1, offsetOut: 2, status: .completed).isUnderway(now: now) == false)
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

    @Test func hostCancelledEventCarriesNoteListingAndFallbackText() throws {
        let repo = InMemoryMessagesRepository()
        let store = MessageStore(repository: repo)

        // The host's optional suggestion and the listing to look at both ride the
        // event, so the guest's card can show the note and offer a way back.
        let event = StayEvent(
            kind: .hostCancelled,
            dateRange: "Mar 3 – Mar 6 · 3 nights",
            note: "So sorry. The week after is open if that helps.",
            listingID: "L1"
        )
        #expect(store.sendStayEvent(event, senderUserID: "host", recipientUserID: "guest"))

        let box = Box<[(messages: [Message], hasMore: Bool)]>([])
        _ = repo.listenToConversation(participants: ["host", "guest"], limit: 10) { result in
            if case .success(let page) = result { box.value.append(page) }
        }
        let stored = box.value.first?.messages.first
        #expect(stored?.event == event)
        #expect(stored?.event?.listingID == "L1")
        // The preview / push fallback reads as a stay ending, not a request.
        #expect(stored?.text == "Stay cancelled · Mar 3 – Mar 6 · 3 nights\nSo sorry. The week after is open if that helps.")
    }

    @Test func hostCancelledFallbackTextOmitsEmptyNote() {
        let event = StayEvent(kind: .hostCancelled, dateRange: "Mar 3 – Mar 6 · 3 nights")
        #expect(event.fallbackText == "Stay cancelled · Mar 3 – Mar 6 · 3 nights")
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

/// The production path builds the thread list from the messages themselves,
/// because the `conversations` summaries the trigger used to write don't exist
/// here. These exercise that grouping directly, with an isolated local-state
/// store so read/mute state doesn't leak between tests or into standard defaults.
struct ConversationSummaryTests {
    private func isolatedState() -> ConversationLocalState {
        let suite = "test.\(UUID().uuidString)"
        return ConversationLocalState(defaults: UserDefaults(suiteName: suite)!)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func oneRowPerCorrespondentNewestFirst() {
        let messages = [
            Message(senderUserID: "bob", text: "older", timestamp: at(100), participants: ["alice", "bob"]),
            Message(senderUserID: "alice", text: "newest to bob", timestamp: at(300), participants: ["alice", "bob"]),
            Message(senderUserID: "carol", text: "hi from carol", timestamp: at(200), participants: ["alice", "carol"]),
        ]
        let convs = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "alice", limit: 10, localState: isolatedState()
        )
        #expect(convs.map(\.id) == ["alice_bob", "alice_carol"])
        // The row's preview is the newest message in the thread, not the newest overall.
        #expect(convs.first?.lastMessage.text == "newest to bob")
    }

    @Test func unreadCountsOnlyTheirMessagesSinceLastRead() {
        let state = isolatedState()
        let messages = [
            Message(senderUserID: "bob", text: "1", timestamp: at(100), participants: ["alice", "bob"]),
            Message(senderUserID: "bob", text: "2", timestamp: at(200), participants: ["alice", "bob"]),
            // Alice's own message never counts against her.
            Message(senderUserID: "alice", text: "reply", timestamp: at(250), participants: ["alice", "bob"]),
            Message(senderUserID: "bob", text: "3", timestamp: at(300), participants: ["alice", "bob"]),
        ]
        // Never opened on this device: everything bob sent is unread.
        var convs = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "alice", limit: 10, localState: state
        )
        #expect(convs.first?.unreadCounts["alice"] == 3)

        // Read at t=200: only bob's later message counts.
        state.markRead(conversationID: "alice_bob", userID: "alice", at: at(200))
        convs = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "alice", limit: 10, localState: state
        )
        #expect(convs.first?.unreadCounts["alice"] == 1)
    }

    @Test func muteStateIsPerUser() {
        let state = isolatedState()
        let messages = [
            Message(senderUserID: "bob", text: "hi", timestamp: at(100), participants: ["alice", "bob"]),
        ]
        state.setMuted(conversationID: "alice_bob", userID: "alice", muted: true)

        let aliceSees = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "alice", limit: 10, localState: state
        )
        #expect(aliceSees.first?.mutedBy == ["alice"])

        // Bob, on his own device, inherits none of alice's mute.
        let bobSees = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "bob", limit: 10, localState: state
        )
        #expect(bobSees.first?.mutedBy == [])
    }

    @Test func limitCapsRowsAfterSortingByRecency() {
        let messages = (1...5).map { i in
            Message(senderUserID: "u\(i)", text: "m\(i)", timestamp: at(Double(i) * 100),
                    participants: ["alice", "u\(i)"].sorted())
        }
        let convs = FirestoreMessagesRepository.summarize(
            messages: messages, userID: "alice", limit: 2, localState: isolatedState()
        )
        // The two most recent threads survive the cap, newest first.
        #expect(convs.count == 2)
        #expect(convs.first?.lastMessage.text == "m5")
    }

    @Test func clearDropsReadAndMuteForThatUser() {
        let state = isolatedState()
        state.markRead(conversationID: "alice_bob", userID: "alice", at: at(500))
        state.setMuted(conversationID: "alice_bob", userID: "alice", muted: true)

        state.clear(userID: "alice")

        #expect(state.lastReadDates(userID: "alice").isEmpty)
        #expect(state.mutedIDs(userID: "alice").isEmpty)
    }
}

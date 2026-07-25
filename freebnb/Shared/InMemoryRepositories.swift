//
//  InMemoryRepositories.swift
//  freebnb
//
//  Lightweight in-memory implementations of the repository protocols for use
//  in SwiftUI previews and unit tests. They do not talk to Firestore.
//

import Foundation

final class InMemoryHomesRepository: HomesRepository, @unchecked Sendable {
    private var homes: [Home]
    private var locations: [String: ListingLocation] = [:]
    private var manuals: [String: HouseManual] = [:]
    private var availability: [String: ListingAvailability] = [:]
    init(homes: [Home] = []) { self.homes = homes }

    /// Mirrors what Firestore's rules would return for `viewerID`: only listings
    /// naming the viewer in `allowedViewerIDs`. Every listing is friends-only,
    /// so a listing not naming the viewer is simply not readable, exactly as
    /// server-side.
    private func visible(to viewerID: String) -> [Home] {
        homes.filter { home in
            !viewerID.isEmpty && (home.allowedViewerIDs ?? []).contains(viewerID)
        }
    }

    func listenToVisibleListings(
        viewerID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let active = recencyOrdered(visible(to: viewerID).filter { $0.deletedAt == nil })
        handler(.success(Array(active.prefix(limit))))
        return NoopListener()
    }

    func listenToManagedListings(
        userID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(homes.filter { $0.isManagedBy(userID) && $0.deletedAt == nil }))
        return NoopListener()
    }

    func fetchVisibleListings(viewerID: String, after cursor: ListingCursor?, limit: Int) async throws -> [Home] {
        let active = recencyOrdered(visible(to: viewerID).filter { $0.deletedAt == nil })
        let start: Int
        if let cursor, let idx = active.firstIndex(where: { $0.id == cursor.id }) {
            start = idx + 1
        } else {
            start = 0
        }
        guard start < active.count else { return [] }
        return Array(active[start...].prefix(limit))
    }

    func save(_ home: Home) async throws {
        if let i = homes.firstIndex(where: { $0.id == home.id }) {
            homes[i] = home
        } else {
            homes.append(home)
        }
    }

    func delete(homeID: String) async throws {
        for i in homes.indices where homes[i].id == homeID {
            homes[i].deletedAt = Date()
        }
    }

    func updateHostName(userID: String, newName: String) async throws {
        for i in homes.indices where homes[i].hostUserID == userID {
            homes[i].hostName = newName
        }
    }

    func softDeleteAllListings(hostUserID: String) async throws {
        for i in homes.indices where homes[i].hostUserID == hostUserID && homes[i].deletedAt == nil {
            homes[i].deletedAt = Date()
        }
    }

    func fetchLocation(homeID: String) async throws -> ListingLocation? {
        locations[homeID]
    }

    func saveLocation(homeID: String, location: ListingLocation) async throws {
        locations[homeID] = location
    }

    func fetchManual(homeID: String) async throws -> HouseManual? {
        manuals[homeID]
    }

    func saveManual(homeID: String, manual: HouseManual) async throws {
        manuals[homeID] = manual
    }

    func fetchAvailability(homeID: String) async throws -> ListingAvailability {
        availability[homeID] ?? ListingAvailability()
    }

    /// Mirrors the merge write: the host's half moves, the server's half stays.
    func saveBlockedRanges(homeID: String, blocked: [DateRange]) async throws {
        var current = availability[homeID] ?? ListingAvailability()
        current.blockedDateRanges = blocked
        availability[homeID] = current
    }

    func saveBookedRanges(homeID: String, booked: [DateRange]) async throws {
        setBookedRanges(homeID: homeID, booked: booked)
    }

    func saveBufferHours(homeID: String, bufferHours: Int) async throws {
        var current = availability[homeID] ?? ListingAvailability()
        current.bufferHours = bufferHours
        availability[homeID] = current
    }

    /// The synchronous form, so a test can put a listing in the state an accepted
    /// stay would leave it in without awaiting.
    func setBookedRanges(homeID: String, booked: [DateRange]) {
        var current = availability[homeID] ?? ListingAvailability()
        current.bookedDateRanges = booked
        availability[homeID] = current
    }
}

final class InMemoryMessagesRepository: MessagesRepository, @unchecked Sendable {
    private var messages: [Message]
    // Mirrors the server-side conversation summaries the onMessageCreated trigger
    // would maintain: per-user read state and mutes for tests and previews.
    private var readCounts: [String: [String: Int]] = [:]  // cid → uid → unread
    private var mutedBy: [String: [String]] = [:]          // cid → [uid]
    init(messages: [Message] = []) { self.messages = messages }

    func listenToConversations(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Conversation], Error>) -> Void
    ) -> RepositoryListener {
        // Group the user's messages into per-conversation summaries, standing in
        // for the denormalized docs a Cloud Function would maintain.
        let grouped = Dictionary(grouping: messages.filter { $0.participants.contains(userID) }) {
            MessageStore.conversationID(userIDs: $0.participants)
        }
        let conversations: [Conversation] = grouped.compactMap { cid, msgs in
            guard let last = msgs.max(by: { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) })
            else { return nil }
            return Conversation(
                id: cid,
                participants: last.participants,
                lastMessage: ConversationLastMessage(
                    text: last.text,
                    senderUserID: last.senderUserID,
                    timestamp: last.timestamp
                ),
                updatedAt: last.timestamp,
                unreadCounts: readCounts[cid] ?? [:],
                mutedBy: mutedBy[cid] ?? []
            )
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        handler(.success(Array(conversations.prefix(limit))))
        return NoopListener()
    }

    func listenToConversation(
        participants: [String],
        limit: Int,
        handler: @escaping @Sendable (Result<(messages: [Message], hasMore: Bool), Error>) -> Void
    ) -> RepositoryListener {
        let sorted = participants.sorted()
        let filtered = messages
            .filter { $0.participants.sorted() == sorted }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        let hasMore = filtered.count > limit
        handler(.success((Array(filtered.prefix(limit)), hasMore)))
        return NoopListener()
    }

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws {
        messages.append(message)
    }

    func markConversationRead(
        conversationID: String,
        userID: String,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        readCounts[conversationID, default: [:]][userID] = 0
    }

    func setConversationMuted(
        conversationID: String,
        userID: String,
        muted: Bool,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        var list = mutedBy[conversationID] ?? []
        if muted {
            if !list.contains(userID) { list.append(userID) }
        } else {
            list.removeAll { $0 == userID }
        }
        mutedBy[conversationID] = list
    }
}

final class InMemoryStayRequestsRepository: StayRequestsRepository, @unchecked Sendable {
    private var requests: [StayRequest] = []
    /// Mirrors the `homes/{id}/accepted/{guestUserID}` markers, so tests can
    /// assert that acceptance discloses the address and a terminal status revokes it.
    private(set) var acceptedGuests: Set<String> = []

    private func markerKey(_ request: StayRequest) -> String {
        "\(request.listingID)/\(request.guestUserID)"
    }

    func hasAddressAccess(listingID: String, guestUserID: String) -> Bool {
        acceptedGuests.contains("\(listingID)/\(guestUserID)")
    }

    /// The stored request, for tests asserting on what a write actually recorded.
    func request(id: String) -> StayRequest? {
        requests.first { $0.id == id }
    }

    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        let filtered = requests.filter { role == .host ? $0.hostUserID == userID : $0.guestUserID == userID }
        handler(.success(filtered))
        return NoopListener()
    }

    func listenToCoHostedRequests(
        listingIDs: [String],
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        guard !listingIDs.isEmpty else { return NoopListener() }
        handler(.success(requests.filter { listingIDs.contains($0.listingID) }))
        return NoopListener()
    }

    /// Records the advanced counter alongside the request so a test can assert
    /// a slot was spent; the cap itself is the rules' business, not this one's.
    private(set) var counters: [String: StayCounter] = [:]

    func create(_ request: StayRequest, advancing counter: StayCounter?) async throws {
        requests.append(request)
        if let counter {
            counters[StayCounter.documentID(hostUserID: counter.hostUserID, guestUserID: counter.guestUserID)] = counter
        }
    }

    func updateListingHostName(hostUserID: String, newName: String) async throws {
        for i in requests.indices where requests[i].hostUserID == hostUserID {
            requests[i].listingHostName = newName
        }
    }

    func updateStatus(
        _ request: StayRequest,
        status: StayRequestStatus,
        hostNote: String?,
        guestNote: String? = nil,
        cancelledBy: String? = nil
    ) async throws {
        if !status.isActive { acceptedGuests.remove(markerKey(request)) }
        guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
        requests[i].status = status
        if let hostNote { requests[i].hostNote = hostNote }
        if let guestNote { requests[i].guestNote = guestNote }
        // Mirrors the write path: recorded only on a cancellation.
        if status == .cancelled { requests[i].cancelledBy = cancelledBy }
    }

    func updateDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws {
        guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
        requests[i].checkIn = checkIn
        requests[i].checkOut = checkOut
    }

    func markCompleted(_ request: StayRequest) async throws {
        guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
        requests[i].status = .completed
        requests[i].completedAt = Date()
        // The address marker survives, exactly as it does server-side: the
        // nightly sweep, not completion, is what revokes it.
    }

    func accept(_ request: StayRequest, hostNote: String?) async throws {
        let conflict = requests.contains { other in
            other.id != request.id &&
            other.listingID == request.listingID &&
            other.status == .accepted &&
            other.overlaps(checkIn: request.checkIn, checkOut: request.checkOut)
        }
        if conflict { throw StayRequestError.overlappingStay }
        try await updateStatus(request, status: .accepted, hostNote: hostNote, cancelledBy: nil)
        acceptedGuests.insert(markerKey(request))
    }
}

final class InMemoryUserProfileRepository: UserProfileRepository, @unchecked Sendable {
    private var profiles: [String: UserProfile]
    init(profiles: [String: UserProfile] = [:]) { self.profiles = profiles }

    func listenToCurrentProfile(
        userID: String,
        handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(profiles[userID]))
        return NoopListener()
    }

    func createInitialProfile(userID: String, displayName: String, email: String?) async throws {
        profiles[userID] = UserProfile(id: userID, displayName: displayName, email: email)
    }

    func updateDisplayName(userID: String, newName: String) async throws {
        profiles[userID]?.displayName = newName
    }

    func updateSavedListings(userID: String, listingIDs: [String]) async throws {
        profiles[userID]?.savedListingIDs = listingIDs
    }

    func updateBlockedUsers(userID: String, blockedUserIDs: [String]) async throws {
        profiles[userID]?.blockedUserIDs = blockedUserIDs
    }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        profiles[userID]
    }

    func updateFCMToken(userID: String, token: String) async throws {
        profiles[userID]?.fcmToken = token
    }

    func updateNotificationPrefs(userID: String, prefs: NotificationPreferences) async throws {
        profiles[userID]?.notificationPrefs = prefs
    }

    func updateEmergencyContact(userID: String, contact: EmergencyContact?) async throws {
        profiles[userID]?.emergencyContact = contact
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return profiles.values
            .filter { $0.displayName.lowercased().contains(needle) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws {}

    func exportUserData() async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["profile": [:], "listings": []], options: [.prettyPrinted])
    }
}

final class InMemoryReviewsRepository: ReviewsRepository, @unchecked Sendable {
    private var reviews: [String: Review] = [:]
    private var feedback: [String: PrivateFeedback] = [:]
    private var references: [String: CharacterReference] = [:]
    /// Stands in for the `mutualFriends` callable, which has no client-side
    /// equivalent: tests seed the answer they expect.
    var mutualFriends: [String: MutualFriends] = [:]

    init(reviews: [Review] = [], references: [CharacterReference] = []) {
        self.reviews = Dictionary(uniqueKeysWithValues: reviews.map { ($0.id, $0) })
        self.references = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
    }

    func fetchReviews(subjectUserID: String) async throws -> [Review] {
        reviews.values.filter { $0.subjectUserID == subjectUserID }.sortedByDate()
    }

    func fetchReviewsWritten(byUserID authorUserID: String) async throws -> [Review] {
        reviews.values.filter { $0.authorUserID == authorUserID }.sortedByDate()
    }

    func submit(_ review: Review, privateFeedback: String?) async throws {
        // Mirrors the rules: an edit preserves createdAt, a create stamps it.
        var stored = review
        stored.createdAt = reviews[review.id]?.createdAt ?? Date()
        stored.updatedAt = Date()
        reviews[review.id] = stored
        if let privateFeedback { feedback[review.id] = PrivateFeedback(text: privateFeedback) }
    }

    func fetchPrivateFeedback(reviewID: String) async throws -> PrivateFeedback? {
        feedback[reviewID]
    }

    func fetchReferences(subjectUserID: String) async throws -> [CharacterReference] {
        references.values
            .filter { $0.subjectUserID == subjectUserID }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func submitReference(_ reference: CharacterReference) async throws {
        var stored = reference
        stored.createdAt = references[reference.id]?.createdAt ?? Date()
        stored.updatedAt = Date()
        references[reference.id] = stored
    }

    func deleteReference(id: String) async throws {
        references.removeValue(forKey: id)
    }

    func fetchMutualFriends(userID: String) async throws -> MutualFriends {
        mutualFriends[userID] ?? .empty
    }
}

final class InMemoryFriendEdgeRepository: FriendEdgeRepository, @unchecked Sendable {
    private var edges: [String: FriendEdge] = [:]

    func listenToEdges(
        userID: String,
        field: String,
        handler: @escaping @Sendable (Result<[FriendEdge], Error>) -> Void
    ) -> RepositoryListener {
        let result = edges.values.filter { edge in
            field == "userA" ? edge.userA == userID : edge.userB == userID
        }
        handler(.success(Array(result)))
        return NoopListener()
    }

    func createEdge(_ edge: FriendEdge) async throws {
        let id = FriendEdge.edgeID(edge.userA, edge.userB)
        var stamped = edge
        stamped.id = id
        edges[id] = stamped
    }

    func updateStatus(edgeID: String, status: FriendStatus) async throws {
        edges[edgeID]?.status = status
    }

    func deleteEdge(edgeID: String) async throws {
        edges.removeValue(forKey: edgeID)
    }

    func fetchSuggestions() async throws -> [FriendSuggestion] { [] }
}

// MARK: - Circles

/// In-memory Circles, for previews and for the unit tests that exercise the
/// store's reconciliation without a backend. Holds one host's world at a time,
/// keyed by host id so a test can still stand up two.
final class InMemoryCircleRepository: CircleRepository, @unchecked Sendable {
    private(set) var circlesByHost: [String: [String: FriendCircle]] = [:]
    private(set) var membersByHost: [String: [String: CircleMembership]] = [:]
    /// The projections a guest would read. Kept so a test can assert the fan-out
    /// actually happened — the projection going stale is the failure mode that
    /// costs a guest a rejected write.
    var publishedByHost: [String: [String: BookingPolicy]] = [:]

    init(circles: [String: [FriendCircle]] = [:], memberships: [String: [CircleMembership]] = [:]) {
        for (host, list) in circles {
            circlesByHost[host] = Dictionary(uniqueKeysWithValues: list.compactMap { c in c.id.map { ($0, c) } })
        }
        for (host, list) in memberships {
            membersByHost[host] = Dictionary(uniqueKeysWithValues: list.compactMap { m in m.id.map { ($0, m) } })
        }
    }

    func listenToCircles(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendCircle], Error>) -> Void
    ) -> RepositoryListener {
        let values = (circlesByHost[hostID] ?? [:]).values
        handler(.success(values.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }))
        return NoopListener()
    }

    func listenToMemberships(
        hostID: String,
        handler: @escaping @Sendable (Result<[CircleMembership], Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(Array((membersByHost[hostID] ?? [:]).values)))
        return NoopListener()
    }

    func saveCircle(hostID: String, _ circle: FriendCircle) async throws {
        guard let id = circle.id else { return }
        circlesByHost[hostID, default: [:]][id] = circle
    }

    func deleteCircle(hostID: String, circleID: String, movingMembers members: [String]) async throws {
        guard circleID != FriendCircle.defaultID else { return }
        circlesByHost[hostID]?.removeValue(forKey: circleID)
        for friendID in members {
            membersByHost[hostID]?[friendID]?.circleID = FriendCircle.defaultID
        }
    }

    func saveMembership(hostID: String, _ membership: CircleMembership, resolvedPolicy: BookingPolicy) async throws {
        guard let friendID = membership.id else { return }
        membersByHost[hostID, default: [:]][friendID] = membership
        publishedByHost[hostID, default: [:]][friendID] = resolvedPolicy
    }

    func publishPolicies(hostID: String, policiesByFriendID: [String: BookingPolicy]) async throws {
        for (friendID, policy) in policiesByFriendID {
            publishedByHost[hostID, default: [:]][friendID] = policy
        }
    }

    func seedCircles(hostID: String) async throws {
        for circle in FriendCircle.seeded() {
            guard let id = circle.id else { continue }
            if circlesByHost[hostID]?[id] == nil {
                circlesByHost[hostID, default: [:]][id] = circle
            }
        }
    }

    func fetchPolicy(hostID: String, guestID: String) async throws -> BookingPolicy? {
        publishedByHost[hostID]?[guestID]
    }

    func fetchStayCounter(hostID: String, guestID: String) async throws -> StayCounter? {
        counters[StayCounter.documentID(hostUserID: hostID, guestUserID: guestID)]
    }

    /// Seedable by a test that wants a guest partway through a frequency window.
    var counters: [String: StayCounter] = [:]
}

// MARK: - Friend notes

/// In-memory private notes, for previews and for the tests that exercise the
/// store without a backend. Keyed by host, because the whole point of the
/// feature is that one host's notes are not another's.
final class InMemoryFriendNoteRepository: FriendNoteRepository, @unchecked Sendable {
    private(set) var notesByHost: [String: [String: FriendNote]] = [:]
    private(set) var promptsByHost: [String: Set<String>] = [:]

    /// Emits on every mutation so a store under test sees a write land the way
    /// it would with a real snapshot listener.
    private var noteHandlers: [String: [@Sendable (Result<[FriendNote], Error>) -> Void]] = [:]
    private var promptHandlers: [String: [@Sendable (Result<Set<String>, Error>) -> Void]] = [:]

    init(notes: [String: [FriendNote]] = [:]) {
        for (host, list) in notes {
            notesByHost[host] = Dictionary(uniqueKeysWithValues: list.compactMap { n in n.id.map { ($0, n) } })
        }
    }

    private func emitNotes(_ hostID: String) {
        let values = Array((notesByHost[hostID] ?? [:]).values).sortedByDate()
        noteHandlers[hostID]?.forEach { $0(.success(values)) }
    }

    private func emitPrompts(_ hostID: String) {
        let values = promptsByHost[hostID] ?? []
        promptHandlers[hostID]?.forEach { $0(.success(values)) }
    }

    func listenToNotes(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendNote], Error>) -> Void
    ) -> RepositoryListener {
        noteHandlers[hostID, default: []].append(handler)
        emitNotes(hostID)
        return NoopListener()
    }

    func listenToPrompts(
        hostID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener {
        promptHandlers[hostID, default: []].append(handler)
        emitPrompts(hostID)
        return NoopListener()
    }

    @discardableResult
    func createNote(hostID: String, _ note: FriendNote) async throws -> String {
        let id = note.id ?? UUID().uuidString
        var stored = note
        stored.id = id
        // The server stamps these; a fake that leaves them nil would make every
        // note in a test sort as "still in flight".
        stored.createdAt = note.createdAt ?? Date()
        stored.updatedAt = stored.createdAt
        notesByHost[hostID, default: [:]][id] = stored
        emitNotes(hostID)
        return id
    }

    func updateNote(hostID: String, noteID: String, text: String, stayRequestID: String?) async throws {
        guard var note = notesByHost[hostID]?[noteID] else { return }
        note.text = text
        note.stayRequestID = stayRequestID
        note.updatedAt = Date()
        notesByHost[hostID]?[noteID] = note
        emitNotes(hostID)
    }

    func deleteNote(hostID: String, noteID: String) async throws {
        notesByHost[hostID]?.removeValue(forKey: noteID)
        emitNotes(hostID)
    }

    func markPromptSeen(hostID: String, stayRequestID: String) async throws {
        promptsByHost[hostID, default: []].insert(stayRequestID)
        emitPrompts(hostID)
    }
}

// MARK: - Guest notes

/// In-memory guest notes, for previews and for the tests that exercise the store
/// without a backend. Keyed by guest, because the whole point of the feature is
/// that one guest's notes are not another's — the mirror of
/// `InMemoryFriendNoteRepository`, keyed by the other party to the same stay.
final class InMemoryGuestNoteRepository: GuestNoteRepository, @unchecked Sendable {
    private(set) var notesByGuest: [String: [String: GuestNote]] = [:]
    private(set) var promptsByGuest: [String: Set<String>] = [:]

    /// Emits on every mutation so a store under test sees a write land the way it
    /// would with a real snapshot listener.
    private var noteHandlers: [String: [@Sendable (Result<[GuestNote], Error>) -> Void]] = [:]
    private var promptHandlers: [String: [@Sendable (Result<Set<String>, Error>) -> Void]] = [:]

    init(notes: [String: [GuestNote]] = [:]) {
        for (guest, list) in notes {
            notesByGuest[guest] = Dictionary(uniqueKeysWithValues: list.compactMap { n in n.id.map { ($0, n) } })
        }
    }

    private func emitNotes(_ guestID: String) {
        let values = Array((notesByGuest[guestID] ?? [:]).values).sortedByDate()
        noteHandlers[guestID]?.forEach { $0(.success(values)) }
    }

    private func emitPrompts(_ guestID: String) {
        let values = promptsByGuest[guestID] ?? []
        promptHandlers[guestID]?.forEach { $0(.success(values)) }
    }

    func listenToNotes(
        guestID: String,
        handler: @escaping @Sendable (Result<[GuestNote], Error>) -> Void
    ) -> RepositoryListener {
        noteHandlers[guestID, default: []].append(handler)
        emitNotes(guestID)
        return NoopListener()
    }

    func listenToPrompts(
        guestID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener {
        promptHandlers[guestID, default: []].append(handler)
        emitPrompts(guestID)
        return NoopListener()
    }

    @discardableResult
    func createNote(guestID: String, _ note: GuestNote) async throws -> String {
        let id = note.id ?? UUID().uuidString
        var stored = note
        stored.id = id
        // The server stamps these; a fake that leaves them nil would make every
        // note in a test sort as "still in flight".
        stored.createdAt = note.createdAt ?? Date()
        stored.updatedAt = stored.createdAt
        notesByGuest[guestID, default: [:]][id] = stored
        emitNotes(guestID)
        return id
    }

    func updateNote(guestID: String, noteID: String, text: String, stayRequestID: String?) async throws {
        guard var note = notesByGuest[guestID]?[noteID] else { return }
        note.text = text
        note.stayRequestID = stayRequestID
        note.updatedAt = Date()
        notesByGuest[guestID]?[noteID] = note
        emitNotes(guestID)
    }

    func deleteNote(guestID: String, noteID: String) async throws {
        notesByGuest[guestID]?.removeValue(forKey: noteID)
        emitNotes(guestID)
    }

    func markPromptSeen(guestID: String, stayRequestID: String) async throws {
        promptsByGuest[guestID, default: []].insert(stayRequestID)
        emitPrompts(guestID)
    }
}

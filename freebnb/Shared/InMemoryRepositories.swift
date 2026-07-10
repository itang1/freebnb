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
    init(homes: [Home] = []) { self.homes = homes }

    /// Mirrors what Firestore's rules would return for `viewerID`: publicly
    /// visible listings, plus any listing naming the viewer in `allowedViewerIDs`.
    /// A listing that is neither is simply not readable, exactly as server-side.
    private func visible(to viewerID: String) -> [Home] {
        homes.filter { home in
            if home.visibility == .friendsOnly {
                return !viewerID.isEmpty && (home.allowedViewerIDs ?? []).contains(viewerID)
            }
            return true
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

    func listenToOwnListings(
        hostUserID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(homes.filter { $0.hostUserID == hostUserID && $0.deletedAt == nil }))
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

    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        let filtered = requests.filter { role == .host ? $0.hostUserID == userID : $0.guestUserID == userID }
        handler(.success(filtered))
        return NoopListener()
    }

    func create(_ request: StayRequest) async throws {
        requests.append(request)
    }

    func updateListingHostName(hostUserID: String, newName: String) async throws {
        for i in requests.indices where requests[i].hostUserID == hostUserID {
            requests[i].listingHostName = newName
        }
    }

    func updateStatus(_ request: StayRequest, status: StayRequestStatus, hostNote: String?) async throws {
        if !status.isActive { acceptedGuests.remove(markerKey(request)) }
        guard let i = requests.firstIndex(where: { $0.id == request.id }) else { return }
        requests[i].status = status
        if let hostNote { requests[i].hostNote = hostNote }
    }

    func accept(_ request: StayRequest, hostNote: String?) async throws {
        let conflict = requests.contains { other in
            other.id != request.id &&
            other.listingID == request.listingID &&
            other.status == .accepted &&
            other.overlaps(checkIn: request.checkIn, checkOut: request.checkOut)
        }
        if conflict { throw StayRequestError.overlappingStay }
        try await updateStatus(request, status: .accepted, hostNote: hostNote)
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

    func deleteProfile(userID: String) async throws {
        profiles.removeValue(forKey: userID)
    }

    func updateFCMToken(userID: String, token: String) async throws {
        profiles[userID]?.fcmToken = token
    }

    func updateNotificationPrefs(userID: String, prefs: NotificationPreferences) async throws {
        profiles[userID]?.notificationPrefs = prefs
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        let q = query.lowercased()
        return profiles.values.filter { $0.displayName.lowercased().hasPrefix(q) }
    }

    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws {}

    func exportUserData() async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["profile": [:], "listings": []], options: [.prettyPrinted])
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
}

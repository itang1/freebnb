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
    init(homes: [Home] = []) { self.homes = homes }

    func listenToListings(
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(Array(homes.filter { $0.deletedAt == nil }.prefix(limit))))
        return NoopListener()
    }

    func listenToOwnListings(
        hostUserID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        handler(.success(homes.filter { $0.hostUserID == hostUserID && $0.deletedAt == nil }))
        return NoopListener()
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
}

final class InMemoryMessagesRepository: MessagesRepository, @unchecked Sendable {
    private var messages: [Message]
    init(messages: [Message] = []) { self.messages = messages }

    func listenToMessages(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Message], Error>) -> Void
    ) -> RepositoryListener {
        let filtered = messages.filter { $0.participants.contains(userID) }
        handler(.success(Array(filtered.prefix(limit))))
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
}

final class InMemoryStayRequestsRepository: StayRequestsRepository, @unchecked Sendable {
    private var requests: [StayRequest] = []

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

    func updateStatus(requestID: String, status: StayRequestStatus, hostNote: String?) async throws {
        guard let i = requests.firstIndex(where: { $0.id == requestID }) else { return }
        requests[i].status = status
        if let hostNote { requests[i].hostNote = hostNote }
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

    func searchProfiles(query: String) async throws -> [UserProfile] {
        let q = query.lowercased()
        return profiles.values.filter { $0.displayName.lowercased().hasPrefix(q) }
    }

    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws {}
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

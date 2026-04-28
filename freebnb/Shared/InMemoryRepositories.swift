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

    func fetchProfile(userID: String) async throws -> UserProfile? {
        profiles[userID]
    }

    func deleteProfile(userID: String) async throws {
        profiles.removeValue(forKey: userID)
    }

    func updateFCMToken(userID: String, token: String) async throws {
        profiles[userID]?.fcmToken = token
    }
}

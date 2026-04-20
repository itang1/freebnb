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
        handler(.success(Array(homes.prefix(limit))))
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
        homes.removeAll { $0.id == homeID }
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

    func fetchProfile(userID: String) async throws -> UserProfile? {
        profiles[userID]
    }
}

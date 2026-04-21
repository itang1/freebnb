//
//  UserProfileStore.swift
//  freebnb
//

import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation
import os

struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    @DocumentID var id: String?
    var displayName: String
    var email: String?
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?
}

@MainActor
@Observable
final class UserProfileStore {
    private(set) var currentProfile: UserProfile?
    private(set) var profileCache: [String: UserProfile] = [:]

    @ObservationIgnored private let repository: UserProfileRepository
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "profile")

    init(repository: UserProfileRepository = FirestoreUserProfileRepository()) {
        self.repository = repository
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartCurrentListener(user: user) }
        }
    }

    deinit {
        activeListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Convenience

    var displayName: String { currentProfile?.displayName ?? "" }

    // MARK: - Current user listener

    private func restartCurrentListener(user: User?) {
        activeListener?.cancel()
        activeListener = nil
        currentProfile = nil
        guard let user, !user.isAnonymous else { return }

        let userID = user.uid
        let email = user.email
        let seedName = UserDefaults.standard.string(forKey: "userName") ?? user.displayName ?? ""

        activeListener = repository.listenToCurrentProfile(userID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handleCurrentProfile(result: result, userID: userID, email: email, seedName: seedName)
            }
        }
    }

    private func handleCurrentProfile(
        result: Result<UserProfile?, Error>,
        userID: String,
        email: String?,
        seedName: String
    ) {
        switch result {
        case .failure(let error):
            log.error("profile snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let profile):
            if let profile {
                currentProfile = profile
                profileCache[userID] = profile
            } else {
                Task { await self.createInitialProfile(userID: userID, displayName: seedName, email: email) }
            }
        }
    }

    private func createInitialProfile(userID: String, displayName: String, email: String?) async {
        do {
            try await repository.createInitialProfile(userID: userID, displayName: displayName, email: email)
        } catch {
            log.error("profile create error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Writes

    func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let userID = Auth.auth().currentUser?.uid else { return }
        do {
            try await repository.updateDisplayName(userID: userID, newName: trimmed)
            UserDefaults.standard.set(trimmed, forKey: "userName")
        } catch {
            log.error("profile update error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lookups for other users

    func profile(for userID: String) -> UserProfile? {
        if let cached = profileCache[userID] { return cached }
        fetchProfile(userID: userID)
        return nil
    }

    func displayName(for userID: String) -> String? {
        profile(for: userID)?.displayName
    }

    private func fetchProfile(userID: String) {
        guard !inFlight.contains(userID) else { return }
        inFlight.insert(userID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(userID) }
            do {
                if let profile = try await self.repository.fetchProfile(userID: userID) {
                    self.profileCache[userID] = profile
                }
            } catch {
                self.log.error("profile fetch error \(userID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

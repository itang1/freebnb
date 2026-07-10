//
//  UserProfileStore.swift
//  freebnb
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    @DocumentID var id: String?
    var displayName: String
    // Reputation, on the world-readable user document because a listing card has
    // to render it without a second fetch per host (feature 2). Written only by
    // the server; `firestore.rules` refuses every client write to it.
    var trustStats: TrustStats?
    var email: String?
    var savedListingIDs: [String]?
    var blockedUserIDs: [String]?
    var fcmToken: String?
    // Per-category push preferences; lives in the private subdocument and is
    // merged in alongside the other owner-only fields. Absent means "all on".
    var notificationPrefs: NotificationPreferences?
    // Who to tell about a stay (feature 5). Owner-only, like the block list.
    var emergencyContact: EmergencyContact?
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    var savedIDs: Set<String> { Set(savedListingIDs ?? []) }
    var blockedIDs: Set<String> { Set(blockedUserIDs ?? []) }
    /// Effective preferences, defaulting to all-enabled when none are stored.
    var effectiveNotificationPrefs: NotificationPreferences { notificationPrefs ?? NotificationPreferences() }
    /// Reputation with an empty record rather than nil, for rendering.
    var effectiveTrustStats: TrustStats { trustStats ?? TrustStats() }
    /// "3 years on FreeBNB", or nil for an account with no creation timestamp.
    var tenureText: String? { TrustStats.tenureText(joinedAt: createdAt) }
}

@MainActor
@Observable
final class UserProfileStore {
    private(set) var currentProfile: UserProfile?
    private(set) var profileCache: [String: UserProfile] = [:]

    @ObservationIgnored private let repository: UserProfileRepository
    // `nonisolated(unsafe)` because `deinit` is nonisolated and must tear
    // these down. Both are only assigned from @MainActor contexts, and
    // Firebase's `ListenerRegistration.remove()` and
    // `Auth.removeStateDidChangeListener(_:)` are thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var hasAttemptedProfileCreation = false
    @ObservationIgnored private let log = AppLog.logger("profile")

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

    var displayName: String? { currentProfile?.displayName }

    // MARK: - Current user listener

    private func restartCurrentListener(user: User?) {
        activeListener?.cancel()
        activeListener = nil
        currentProfile = nil
        hasAttemptedProfileCreation = false
        guard let user, !user.isAnonymous else { return }

        let userID = user.uid
        let email = user.email
        let rawSeed = UserDefaults.standard.string(forKey: UserDefaultsKey.userName) ?? user.displayName ?? ""
        let seedName = rawSeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (user.email.flatMap { $0.components(separatedBy: "@").first } ?? "FreeBNB User")
            : rawSeed

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
            } else if !hasAttemptedProfileCreation {
                hasAttemptedProfileCreation = true
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

    enum ProfileUpdateError: LocalizedError {
        case emptyName
        case notSignedIn
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .emptyName:          return "Name can’t be empty."
            case .notSignedIn:        return "You need to be signed in to update your profile."
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    func isSaved(_ listingID: String) -> Bool {
        currentProfile?.savedIDs.contains(listingID) ?? false
    }

    func toggleSavedListing(_ listingID: String) async throws {
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        var ids = currentProfile?.savedIDs ?? []
        if ids.contains(listingID) { ids.remove(listingID) } else { ids.insert(listingID) }
        let newIDs = Array(ids)

        // Optimistic local update so the filter and icon reflect the change
        // immediately without waiting for the Firestore listener round-trip.
        let snapshot = currentProfile
        currentProfile?.savedListingIDs = newIDs

        do {
            try await repository.updateSavedListings(userID: userID, listingIDs: newIDs)
        } catch {
            currentProfile = snapshot          // revert on failure
            log.error("saved listings update error: \(error.localizedDescription, privacy: .public)")
            throw ProfileUpdateError.underlying(error)
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ProfileUpdateError.emptyName }
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        do {
            try await repository.updateDisplayName(userID: userID, newName: trimmed)
            UserDefaults.standard.set(trimmed, forKey: UserDefaultsKey.userName)
        } catch {
            log.error("profile update error: \(error.localizedDescription, privacy: .public)")
            throw ProfileUpdateError.underlying(error)
        }
    }

    func isBlocked(_ userID: String) -> Bool {
        currentProfile?.blockedIDs.contains(userID) ?? false
    }

    func blockUser(_ userID: String) async throws {
        guard let myID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        var ids = currentProfile?.blockedIDs ?? []
        ids.insert(userID)
        try await repository.updateBlockedUsers(userID: myID, blockedUserIDs: Array(ids))
    }

    func unblockUser(_ userID: String) async throws {
        guard let myID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        var ids = currentProfile?.blockedIDs ?? []
        ids.remove(userID)
        try await repository.updateBlockedUsers(userID: myID, blockedUserIDs: Array(ids))
    }

    func submitReport(targetType: String, targetID: String, reason: String) async throws {
        guard let myID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        try await repository.submitReport(reporterUserID: myID, targetType: targetType, targetID: targetID, reason: reason)
    }

    /// Persists per-category push preferences to the private profile. Updates the
    /// local copy optimistically so the toggle reflects the change without waiting
    /// for the listener round-trip; reverts on failure.
    func updateNotificationPrefs(_ prefs: NotificationPreferences) async throws {
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        let snapshot = currentProfile
        currentProfile?.notificationPrefs = prefs
        do {
            try await repository.updateNotificationPrefs(userID: userID, prefs: prefs)
        } catch {
            currentProfile = snapshot
            log.error("notification prefs update error: \(error.localizedDescription, privacy: .public)")
            throw ProfileUpdateError.underlying(error)
        }
    }

    /// Stores, or with nil clears, the person this user shares their stays with
    /// (feature 5). Optimistic like the notification toggles, and reverted on
    /// failure so the form never claims a save that didn't land.
    func updateEmergencyContact(_ contact: EmergencyContact?) async throws {
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileUpdateError.notSignedIn }
        let snapshot = currentProfile
        currentProfile?.emergencyContact = contact
        do {
            try await repository.updateEmergencyContact(userID: userID, contact: contact)
        } catch {
            currentProfile = snapshot
            log.error("emergency contact update error: \(error.localizedDescription, privacy: .public)")
            throw ProfileUpdateError.underlying(error)
        }
    }

    /// Fetches the user's full data export and writes it to a temporary JSON file,
    /// returning its URL for the share sheet (L12). The caller owns presenting it.
    func exportDataFile() async throws -> URL {
        let data = try await repository.exportUserData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FreeBNB-my-data.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func saveFCMToken(_ token: String) async throws {
        guard let userID = Auth.auth().currentUser?.uid else { return }
        do {
            try await repository.updateFCMToken(userID: userID, token: token)
        } catch {
            log.error("FCM token update error: \(error.localizedDescription, privacy: .public)")
            throw ProfileUpdateError.underlying(error)
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

    /// Awaits a definitive lookup of a single profile (unlike `profile(for:)`,
    /// which returns nil immediately and fetches in the background). Used to
    /// validate that an invite deep link's inviter is a real user before the
    /// app prompts to send them a friend request. Returns nil if no such user
    /// exists or the fetch fails.
    func fetchProfileOnce(userID: String) async -> UserProfile? {
        if let cached = profileCache[userID] { return cached }
        do {
            if let profile = try await repository.fetchProfile(userID: userID) {
                profileCache[userID] = profile
                return profile
            }
        } catch {
            log.error("invite profile fetch error \(userID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        let results = try await repository.searchProfiles(query: query)
        for p in results {
            if let id = p.id { profileCache[id] = p }
        }
        return results
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

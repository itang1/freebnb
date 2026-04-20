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

    @ObservationIgnored nonisolated(unsafe) private var currentListener: ListenerRegistration?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let db = Firestore.firestore()
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "profile")

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartCurrentListener(user: user) }
        }
    }

    deinit {
        currentListener?.remove()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Convenience

    var displayName: String { currentProfile?.displayName ?? "" }

    // MARK: - Current user listener

    private func restartCurrentListener(user: User?) {
        currentListener?.remove()
        currentListener = nil
        currentProfile = nil
        guard let user, !user.isAnonymous else { return }

        let userID = user.uid
        let email = user.email
        let seedName = UserDefaults.standard.string(forKey: "userName") ?? user.displayName ?? ""

        currentListener = db.collection("users").document(userID)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    self?.handleCurrentSnapshot(
                        snapshot: snapshot,
                        error: error,
                        userID: userID,
                        email: email,
                        seedName: seedName
                    )
                }
            }
    }

    private func handleCurrentSnapshot(
        snapshot: DocumentSnapshot?,
        error: Error?,
        userID: String,
        email: String?,
        seedName: String
    ) {
        if let error {
            log.error("profile snapshot error: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let snapshot else { return }
        if snapshot.exists {
            do {
                let profile = try snapshot.data(as: UserProfile.self)
                currentProfile = profile
                profileCache[userID] = profile
            } catch {
                log.error("profile decode error \(userID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            Task { await self.createInitialProfile(userID: userID, displayName: seedName, email: email) }
        }
    }

    private func createInitialProfile(userID: String, displayName: String, email: String?) async {
        var data: [String: Any] = [
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let email { data["email"] = email }
        do {
            try await db.collection("users").document(userID).setData(data)
        } catch {
            log.error("profile create error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Writes

    func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let userID = Auth.auth().currentUser?.uid else { return }
        do {
            try await db.collection("users").document(userID).setData([
                "displayName": trimmed,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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
                let snap = try await self.db.collection("users").document(userID).getDocument()
                guard snap.exists else { return }
                let profile = try snap.data(as: UserProfile.self)
                self.profileCache[userID] = profile
            } catch {
                self.log.error("profile fetch error \(userID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

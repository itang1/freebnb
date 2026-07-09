//
//  UserProfileRepository.swift
//  freebnb
//
//  Public and private user profiles, blocking, reports, and account deletion.
//  Split out of the former Repositories.swift (A2).
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

protocol UserProfileRepository: Sendable {
    func listenToCurrentProfile(
        userID: String,
        handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void
    ) -> RepositoryListener

    func createInitialProfile(userID: String, displayName: String, email: String?) async throws
    func updateDisplayName(userID: String, newName: String) async throws
    func updateSavedListings(userID: String, listingIDs: [String]) async throws
    func updateBlockedUsers(userID: String, blockedUserIDs: [String]) async throws
    func fetchProfile(userID: String) async throws -> UserProfile?
    func deleteProfile(userID: String) async throws
    func updateFCMToken(userID: String, token: String) async throws
    func searchProfiles(query: String) async throws -> [UserProfile]
    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws
}

// Sensitive profile fields (email, fcmToken, blockedUserIDs, savedListingIDs)
// live in this owner-only subdocument, split out of the world-readable user
// doc so they are never exposed to other users. Clients read/write them only
// for the current user; Cloud Functions reach them via elevated access.
private let privateProfileDocID = FirestorePaths.profileDocID

/// Merges the public user document with the owner-only private subdocument into
/// one `UserProfile`. Firestore delivers snapshot callbacks on the main queue by
/// default, so the mutable state below is accessed serially without locking.
private final class CurrentProfileMerger: @unchecked Sendable {
    private let handler: @Sendable (Result<UserProfile?, Error>) -> Void
    private var publicProfile: UserProfile?
    private var hasPublic = false
    private var email: String?
    private var fcmToken: String?
    private var blockedUserIDs: [String]?
    private var savedListingIDs: [String]?

    init(handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void) {
        self.handler = handler
    }

    func setPublic(snapshot: DocumentSnapshot?, error: Error?) {
        if let error { handler(.failure(error)); return }
        hasPublic = true
        guard let snapshot, snapshot.exists else {
            publicProfile = nil
            emit()
            return
        }
        do {
            publicProfile = try snapshot.data(as: UserProfile.self)
            emit()
        } catch {
            handler(.failure(error))
        }
    }

    func setPrivate(snapshot: DocumentSnapshot?) {
        let data = snapshot?.data()
        email = data?["email"] as? String
        fcmToken = data?["fcmToken"] as? String
        blockedUserIDs = data?["blockedUserIDs"] as? [String]
        savedListingIDs = data?["savedListingIDs"] as? [String]
        if hasPublic { emit() }
    }

    private func emit() {
        guard hasPublic else { return }
        guard var profile = publicProfile else {
            handler(.success(nil))
            return
        }
        profile.email = email
        profile.fcmToken = fcmToken
        profile.blockedUserIDs = blockedUserIDs
        profile.savedListingIDs = savedListingIDs
        handler(.success(profile))
    }
}

struct FirestoreUserProfileRepository: UserProfileRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func privateDoc(_ userID: String) -> DocumentReference {
        db.collection(FirestorePaths.users).document(userID)
            .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
    }

    func listenToCurrentProfile(
        userID: String,
        handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void
    ) -> RepositoryListener {
        let publicRef = db.collection(FirestorePaths.users).document(userID)
        let merger = CurrentProfileMerger(handler: handler)
        let publicReg = publicRef.addSnapshotListener { snapshot, error in
            merger.setPublic(snapshot: snapshot, error: error)
        }
        let privateReg = privateDoc(userID).addSnapshotListener { snapshot, error in
            // A missing/unreadable private doc is normal for brand-new or
            // pre-split accounts; treat it as "no private data yet" rather than
            // failing the whole profile load, which the public listener owns.
            merger.setPrivate(snapshot: error == nil ? snapshot : nil)
        }
        return CompositeListener(listeners: [
            FirestoreListenerBox(publicReg),
            FirestoreListenerBox(privateReg)
        ])
    }

    func createInitialProfile(userID: String, displayName: String, email: String?) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID).setData([
                "displayName": displayName,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
            var privateData: [String: Any] = ["updatedAt": FieldValue.serverTimestamp()]
            if let email { privateData["email"] = email }
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData(privateData, merge: true)
        }
    }

    func updateDisplayName(userID: String, newName: String) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID).setData([
                "displayName": newName,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    func updateSavedListings(userID: String, listingIDs: [String]) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData([
                    "savedListingIDs": listingIDs,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func updateBlockedUsers(userID: String, blockedUserIDs: [String]) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData([
                    "blockedUserIDs": blockedUserIDs,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws {
        let payload: [String: Any] = [
            "reporterUserID": reporterUserID,
            "targetType": targetType,
            "targetID": targetID,
            "reason": reason,
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await withRetry { [db] in
            _ = try await db.collection(FirestorePaths.reports).addDocument(data: payload)
        }
    }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.users).document(userID).getDocument()
            guard snap.exists else { return nil }
            return try snap.data(as: UserProfile.self)
        }
    }

    func deleteProfile(userID: String) async throws {
        try await withRetry { [db] in
            // Remove the private subdocument first, then the public doc.
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID).delete()
            try await db.collection(FirestorePaths.users).document(userID).delete()
        }
    }

    func updateFCMToken(userID: String, token: String) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData([
                    "fcmToken": token,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let end = trimmed + "\u{f8ff}"
        let snap = try await db.collection(FirestorePaths.users)
            .whereField("displayName", isGreaterThanOrEqualTo: trimmed)
            .whereField("displayName", isLessThan: end)
            .limit(to: 10)
            .getDocuments()
        return snap.documents.compactMap { try? $0.data(as: UserProfile.self) }
    }
}

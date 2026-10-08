//
//  UserProfileRepository.swift
//  freebnb
//
//  Public and private user profiles, blocking, reports and account deletion.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

/// The `searchTerms` index on the public user doc and the client's matching rules.
///
/// Firestore has no substring operator, so a name is decomposed on write into the
/// prefixes someone might type, and a search is one `arrayContains`. A query
/// matches when every query word prefixes some word of the name ("spo", "square"
/// and "sponge square" all find "SpongeBob SquarePants"); mid-word fragments
/// don't, since storing every substring is quadratic.
///
/// Keep in step with `scripts/search_terms.js`; a test pins the two outputs together.
enum UserSearchTerms {
    /// Longer prefixes aren't stored; longer queries are truncated for the lookup
    /// and re-checked in full client-side.
    static let maxPrefixLength = 15
    /// Bounds the document and what a modified client can stuff in; mirrors `isValidSearchTerms` in
    /// firestore.rules.
    static let maxTerms = 60

    static func words(in name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Every prefix of every word plus the whole lowercased name, which the rules require.
    static func terms(for displayName: String) -> [String] {
        var terms: Set<String> = []
        for word in words(in: displayName) {
            let capped = word.prefix(maxPrefixLength)
            for length in 1...max(capped.count, 1) where length <= capped.count {
                terms.insert(String(capped.prefix(length)))
            }
        }
        let fullName = displayName.lowercased()
        terms.remove(fullName)
        // Sorted so the array is stable across writes; a Set would rewrite the field every save.
        return [fullName] + terms.sorted().prefix(maxTerms - 1)
    }

    /// The single term to query on: the longest word, the most selective.
    static func queryTerm(for query: String) -> String? {
        words(in: query)
            .max(by: { $0.count < $1.count })
            .map { String($0.prefix(maxPrefixLength)) }
    }

    /// True when every word of `query` prefixes some word of `displayName`; makes multi-word queries mean all
    /// words.
    static func matches(displayName: String, query: String) -> Bool {
        let nameWords = words(in: displayName)
        let queryWords = words(in: query)
        guard !queryWords.isEmpty else { return false }
        return queryWords.allSatisfy { queryWord in
            nameWords.contains { $0.hasPrefix(queryWord) }
        }
    }
}

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
    // No `deleteProfile`: account deletion is the `deleteUser` callable's job.
    // The public user doc is undeletable by clients while the private subdoc is,
    // so a client cascade would delete `blockedUserIDs`, fail on the rest, and
    // silently lift every block the user had placed.
    func updateFCMToken(userID: String, token: String) async throws
    func updateNotificationPrefs(userID: String, prefs: NotificationPreferences) async throws
    /// Stores (or with nil clears) the person this user shares stays with; private subdocument only.
    func updateEmergencyContact(userID: String, contact: EmergencyContact?) async throws
    func searchProfiles(query: String) async throws -> [UserProfile]
    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws
    /// Invokes the `exportUserData` callable and returns pretty-printed JSON (GDPR/CCPA access).
    func exportUserData() async throws -> Data
}

// Sensitive fields (email, fcmToken, blockedUserIDs, savedListingIDs) live in
// this owner-only subdocument, split from the world-readable user doc.
private let privateProfileDocID = FirestorePaths.profileDocID

/// Merges the public user document with the owner-only subdocument into one
/// `UserProfile`. Snapshots arrive on the main queue, so state is accessed serially.
private final class CurrentProfileMerger: @unchecked Sendable {
    private let handler: @Sendable (Result<UserProfile?, Error>) -> Void
    private var publicProfile: UserProfile?
    private var hasPublic = false
    private var email: String?
    private var fcmToken: String?
    private var blockedUserIDs: [String]?
    private var savedListingIDs: [String]?
    private var notificationPrefs: NotificationPreferences?
    private var emergencyContact: EmergencyContact?

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
        notificationPrefs = NotificationPreferences(firestore: data?["notificationPrefs"] as? [String: Any])
        emergencyContact = EmergencyContact(firestore: data?["emergencyContact"] as? [String: Any])
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
        profile.notificationPrefs = notificationPrefs
        profile.emergencyContact = emergencyContact
        handler(.success(profile))
    }
}

struct FirestoreUserProfileRepository: UserProfileRepository {
    private let db: Firestore
    private let functions: Functions
    init(db: Firestore = .firestore(), functions: Functions = .functions()) {
        self.db = db
        self.functions = functions
    }

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
            // A missing private doc is normal for new or pre-split accounts; the public listener owns load
            // failures.
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
                "searchTerms": UserSearchTerms.terms(for: displayName),
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
                // Must move with the name, or the stale index keeps finding the old one and the rules reject it.
                "searchTerms": UserSearchTerms.terms(for: newName),
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
            // Enters the moderation queue at the top; the rules pin a `new` report from a person.
            "status": "new",
            "source": "user",
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

    func updateNotificationPrefs(userID: String, prefs: NotificationPreferences) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData([
                    "notificationPrefs": prefs.firestoreValue,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func updateEmergencyContact(userID: String, contact: EmergencyContact?) async throws {
        let value: Any = contact.map { $0.firestoreValue as Any } ?? FieldValue.delete()
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.users).document(userID)
                .collection(FirestorePaths.privateCollection).document(privateProfileDocID)
                .setData([
                    "emergencyContact": value,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func exportUserData() async throws -> Data {
        let result = try await functions.httpsCallable("exportUserData").call()
        // The callable returns a JSON-compatible graph; serialize stably for a readable file.
        return try JSONSerialization.data(
            withJSONObject: result.data,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        // One lookup against the `searchTerms` array (see UserSearchTerms), replacing
        // a local scan of the first 200 users that couldn't find user 201.
        guard let term = UserSearchTerms.queryTerm(for: query) else { return [] }
        let snap = try await db.collection(FirestorePaths.users)
            .whereField("searchTerms", arrayContains: term)
            .limit(to: Self.searchResultLimit)
            .getDocuments()
        return snap.documents
            .compactMap { try? $0.data(as: UserProfile.self) }
            // The lookup only carried the longest word; re-check the whole query.
            .filter { UserSearchTerms.matches(displayName: $0.displayName, query: query) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Upper bound on results per search; bounds a selective query's result set.
    private static let searchResultLimit = 50
}

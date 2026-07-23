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

/// The `searchTerms` index on the public user doc, and the matching rules the
/// client applies on top of it.
///
/// Name search has no server-side substring operator in Firestore, so a name is
/// decomposed on write into the prefixes someone might type, and a search is one
/// `arrayContains` against that. This is what replaced downloading the first 200
/// user docs and substring-matching locally, which silently could not find user
/// 201.
///
/// Semantics: a query matches when **every** query word prefixes **some** word of
/// the name — "spo", "square", and "sponge square" all find "SpongeBob
/// SquarePants". A mid-word fragment ("quare") does not, which the old local scan
/// did handle; storing every substring rather than every prefix is quadratic in
/// the name's length, and leading-edge typing is what a name search is actually
/// for.
///
/// Keep in step with `scripts/search_terms.js`, the Node twin the seed script
/// builds the same array from. A profile indexed by one and queried through the
/// other is a user search cannot find, so a test pins the two outputs together.
enum UserSearchTerms {
    /// Longer prefixes than this aren't stored: a query longer than the cap is
    /// truncated to it for the lookup, and the client-side pass below re-checks
    /// the full query anyway.
    static let maxPrefixLength = 15
    /// Bounds both the document and what a modified client can stuff in. The
    /// rules enforce the same number; see `isValidSearchTerms` in firestore.rules.
    static let maxTerms = 60

    static func words(in name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Every prefix of every word, plus the whole lowercased name — the rules
    /// require that last one to be present, so a document cannot claim search
    /// terms while hiding the name they supposedly came from.
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
        // Sorted so the array is stable across writes: an unordered Set would
        // rewrite the field (and bill an index update) on every save.
        return [fullName] + terms.sorted().prefix(maxTerms - 1)
    }

    /// The single term to query on: the longest word, because it is the most
    /// selective. Everything else about the query is re-checked client-side.
    static func queryTerm(for query: String) -> String? {
        words(in: query)
            .max(by: { $0.count < $1.count })
            .map { String($0.prefix(maxPrefixLength)) }
    }

    /// True when every word of `query` prefixes some word of `displayName`. The
    /// `arrayContains` lookup only covers one query word, so this is what makes a
    /// multi-word query mean all of its words.
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
    // No `deleteProfile`. Account deletion is the `deleteUser` callable's job and
    // cannot be done from the client: `firestore.rules` sets `allow delete: if
    // false` on the public user document, while the owner-only private
    // subdocument *is* client-deletable. A client-side cascade therefore deletes
    // the private half, is denied the public half, and — because permission
    // denied is not a transient error and `withRetry` will not retry it — leaves
    // the account with its `blockedUserIDs` gone. `hasBlocked()` reads a missing
    // document as "not blocked", so a failed self-delete would silently lift
    // every block the user had placed. The method that did this was unreferenced
    // and has been removed rather than left as a trap.
    func updateFCMToken(userID: String, token: String) async throws
    func updateNotificationPrefs(userID: String, prefs: NotificationPreferences) async throws
    /// Stores (or, with nil, clears) the person this user shares their stays with.
    /// Owner-only data: it never leaves the private subdocument.
    func updateEmergencyContact(userID: String, contact: EmergencyContact?) async throws
    func searchProfiles(query: String) async throws -> [UserProfile]
    func submitReport(reporterUserID: String, targetType: String, targetID: String, reason: String) async throws
    /// Invokes the `exportUserData` callable and returns the result as
    /// pretty-printed JSON, fulfilling the GDPR/CCPA right-to-access (L12).
    func exportUserData() async throws -> Data
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
                // Must move with the name: a stale index would keep finding this
                // user under the old one, and the rules reject terms that don't
                // carry the current name.
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
            // Enters the moderation console's queue at the top (feature 6). The
            // rules pin both of these on create: a user files a `new` report from
            // a person, never an `actioned` one or one impersonating the
            // keyword-moderation triggers.
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
        // The callable returns a JSON-compatible object graph (dictionaries,
        // arrays, numbers, strings, and Timestamp maps). Serialize it stably so
        // the shared file is human-readable.
        return try JSONSerialization.data(
            withJSONObject: result.data,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func searchProfiles(query: String) async throws -> [UserProfile] {
        // One indexed lookup against the `searchTerms` array the write path
        // maintains (see UserSearchTerms). The predecessor read the first 200
        // user docs in arbitrary order and matched locally, so user 201 was
        // unfindable no matter what they typed; this asks the server for the
        // matches instead, and the directory can grow.
        guard let term = UserSearchTerms.queryTerm(for: query) else { return [] }
        let snap = try await db.collection(FirestorePaths.users)
            .whereField("searchTerms", arrayContains: term)
            .limit(to: Self.searchResultLimit)
            .getDocuments()
        return snap.documents
            .compactMap { try? $0.data(as: UserProfile.self) }
            // The lookup only carried the longest query word. Re-check the whole
            // query so "sponge square" doesn't match everyone named Square.
            .filter { UserSearchTerms.matches(displayName: $0.displayName, query: query) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Upper bound on results per search. This one bounds the *result set* of a
    /// selective query rather than a blind scan of the directory, so a name with
    /// more matches than this is a reason to type more, not a silent cliff.
    private static let searchResultLimit = 50
}

//
//  Repositories.swift
//  freebnb
//
//  Protocols isolating the stores from Firestore so tests and previews can
//  swap in in-memory implementations.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import os

// MARK: - Shared

enum AppLog {
    static let subsystem = "com.freebnb.app"
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

protocol RepositoryListener: Sendable {
    func cancel()
}

struct NoopListener: RepositoryListener {
    func cancel() {}
}

final class FirestoreListenerBox: RepositoryListener, @unchecked Sendable {
    private let inner: ListenerRegistration
    init(_ inner: ListenerRegistration) { self.inner = inner }
    func cancel() { inner.remove() }
}

private let repoLog = AppLog.logger("repository")

// Upper bounds for otherwise-unbounded snapshot listeners so a heavy account
// doesn't download an ever-growing collection on every launch. Paging can be
// layered on later; these caps keep read cost predictable in the meantime.
private let ownListingsListenerLimit = 200
private let stayRequestsListenerLimit = 200
private let friendEdgesListenerLimit = 500

// Firestore caps a WriteBatch at 500 operations.
private let firestoreBatchLimit = 500

// MARK: - Retry helper

/// Retries `operation` up to `maxAttempts` times using exponential backoff
/// with full jitter. Only retries on transient Firestore errors (unavailable,
/// deadline exceeded, internal, resource exhausted). Gives up immediately on
/// permission errors or other unrecoverable failures.
func withRetry<T>(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 0.5,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            attempt += 1
            let isTransient = isTransientFirestoreError(error)
            guard isTransient && attempt < maxAttempts else { throw error }
            let cap = baseDelay * pow(2.0, Double(attempt - 1))
            let jitter = Double.random(in: 0...cap)
            try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
        }
    }
}

private func isTransientFirestoreError(_ error: Error) -> Bool {
    let nsErr = error as NSError
    // Firestore error codes that indicate a transient condition:
    // 14 = unavailable, 4 = deadline exceeded, 13 = internal, 8 = resource exhausted
    let transientCodes: Set<Int> = [4, 8, 13, 14]
    if nsErr.domain == "FIRFirestoreErrorDomain" {
        return transientCodes.contains(nsErr.code)
    }
    // Also catch NSURLErrorNetworkConnectionLost and similar URLSession errors.
    if nsErr.domain == NSURLErrorDomain {
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorNotConnectedToInternet].contains(nsErr.code)
    }
    return false
}

// MARK: - Homes

protocol HomesRepository: Sendable {
    func listenToListings(
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    func listenToOwnListings(
        hostUserID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    func save(_ home: Home) async throws
    func delete(homeID: String) async throws
    func updateHostName(userID: String, newName: String) async throws
    func softDeleteAllListings(hostUserID: String) async throws
}

struct FirestoreHomesRepository: HomesRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToListings(
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection("homes")
            .order(by: FieldPath.documentID())
            .limit(to: limit)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                if let error { handler(.failure(error)); return }
                guard let snapshot else { return }
                // Skip an empty cached snapshot — wait for the server confirmation
                // so the UI doesn't flash "no listings" before real data arrives.
                if snapshot.metadata.isFromCache && snapshot.isEmpty { return }
                let homes: [Home] = snapshot.documents.compactMap { doc in
                    do { return try doc.data(as: Home.self) }
                    catch {
                        repoLog.error("home decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success(homes))
            }
        return FirestoreListenerBox(reg)
    }

    func listenToOwnListings(
        hostUserID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection("homes")
            .whereField("hostUserID", isEqualTo: hostUserID)
            // Bound the listener so a prolific host doesn't stream every
            // listing they've ever created on each launch.
            .limit(to: ownListingsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let homes: [Home] = (snapshot?.documents ?? []).compactMap { doc in
                    do { return try doc.data(as: Home.self) }
                    catch {
                        repoLog.error("own home decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success(homes))
            }
        return FirestoreListenerBox(reg)
    }

    func save(_ home: Home) async throws {
        try await withRetry { [db] in
            try db.collection("homes").document(home.id).setData(from: home)
        }
    }

    func delete(homeID: String) async throws {
        try await withRetry { [db] in
            try await db.collection("homes").document(homeID).updateData([
                "deletedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func updateHostName(userID: String, newName: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection("homes")
                .whereField("hostUserID", isEqualTo: userID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            // Commit in chunks of 500 so a prolific host's rename doesn't
            // exceed Firestore's per-batch write limit.
            for start in stride(from: 0, to: refs.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for ref in refs[start..<min(start + firestoreBatchLimit, refs.count)] {
                    batch.updateData(["hostName": newName], forDocument: ref)
                }
                try await batch.commit()
            }
        }
    }

    func softDeleteAllListings(hostUserID: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection("homes")
                .whereField("hostUserID", isEqualTo: hostUserID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            let now = Timestamp(date: Date())
            // Chunk under the 500-op batch cap for hosts with many listings.
            for start in stride(from: 0, to: refs.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for ref in refs[start..<min(start + firestoreBatchLimit, refs.count)] {
                    batch.updateData(["deletedAt": now], forDocument: ref)
                }
                try await batch.commit()
            }
        }
    }
}

// MARK: - Photo uploads

protocol PhotoUploader: Sendable {
    /// Uploads an image and returns the public download URL. Implementations
    /// should scope storage paths by listing so rules can enforce ownership.
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL
}

enum PhotoUploaderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Photo uploads aren't set up yet. Enable Firebase Storage and add a PhotoUploader implementation."
        }
    }
}

/// Default stand-in so the rest of the app can be built and run without
/// Firebase Storage linked. Any attempt to upload throws `notConfigured`
/// so failures are loud, not silent.
struct NoopPhotoUploader: PhotoUploader {
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL {
        throw PhotoUploaderError.notConfigured
    }
}

// MARK: - Messages

protocol MessagesRepository: Sendable {
    /// Broad listener used to build the conversation list. Fetches the most
    /// recent `limit` messages across all of the user's conversations.
    func listenToMessages(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Message], Error>) -> Void
    ) -> RepositoryListener

    /// Focused listener for a single conversation thread. `participants` must
    /// be the sorted [userA, userB] pair. Fetches the most recent `limit`
    /// messages and calls handler with `hasMore = true` when a full page
    /// arrived (so the caller can offer a "load older" action).
    func listenToConversation(
        participants: [String],
        limit: Int,
        handler: @escaping @Sendable (Result<(messages: [Message], hasMore: Bool), Error>) -> Void
    ) -> RepositoryListener

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws
}

struct FirestoreMessagesRepository: MessagesRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToMessages(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Message], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection("messages")
            .whereField("participants", arrayContains: userID)
            .order(by: "timestamp", descending: true)
            .limit(to: limit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let messages: [Message] = docs.compactMap { doc in
                    do { return try doc.data(as: Message.self) }
                    catch {
                        repoLog.error("msg decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success(messages))
            }
        return FirestoreListenerBox(reg)
    }

    func listenToConversation(
        participants: [String],
        limit: Int,
        handler: @escaping @Sendable (Result<(messages: [Message], hasMore: Bool), Error>) -> Void
    ) -> RepositoryListener {
        // Fetch limit+1 to detect whether older messages exist.
        let reg = db.collection("messages")
            .whereField("participants", isEqualTo: participants.sorted())
            .order(by: "timestamp", descending: true)
            .limit(to: limit + 1)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let hasMore = docs.count > limit
                let messages: [Message] = docs.prefix(limit).compactMap { doc in
                    do { return try doc.data(as: Message.self) }
                    catch {
                        repoLog.error("conv msg decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success((messages, hasMore)))
            }
        return FirestoreListenerBox(reg)
    }

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws {
        let ref = db.collection("messages").document(message.id)
        try ref.setData(from: message) { error in
            if let error { onError(error) }
        }
    }
}

// MARK: - Stay requests

protocol StayRequestsRepository: Sendable {
    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener

    func create(_ request: StayRequest) async throws
    func updateStatus(requestID: String, status: StayRequestStatus, hostNote: String?) async throws
}

struct FirestoreStayRequestsRepository: StayRequestsRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        let field = role == .guest ? "guestUserID" : "hostUserID"
        let reg = db.collection("stayRequests")
            .whereField(field, isEqualTo: userID)
            .order(by: "createdAt", descending: true)
            // Bound the listener; most-recent-first keeps active requests in view.
            .limit(to: stayRequestsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let requests: [StayRequest] = docs.compactMap { doc in
                    do { return try doc.data(as: StayRequest.self) }
                    catch {
                        repoLog.error("request decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success(requests))
            }
        return FirestoreListenerBox(reg)
    }

    func create(_ request: StayRequest) async throws {
        try await withRetry { [db] in
            try db.collection("stayRequests").document(request.id).setData(from: request)
        }
    }

    func updateStatus(requestID: String, status: StayRequestStatus, hostNote: String?) async throws {
        var data: [String: Any] = [
            "status": status.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let hostNote { data["hostNote"] = hostNote }
        let payload = data
        try await withRetry { [db] in
            try await db.collection("stayRequests").document(requestID).updateData(payload)
        }
    }
}

// MARK: - User profiles

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
private let privateProfileDocID = "profile"

/// Cancels several underlying listeners as a single unit.
struct CompositeListener: RepositoryListener {
    let listeners: [RepositoryListener]
    func cancel() { listeners.forEach { $0.cancel() } }
}

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
        db.collection("users").document(userID)
            .collection("private").document(privateProfileDocID)
    }

    func listenToCurrentProfile(
        userID: String,
        handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void
    ) -> RepositoryListener {
        let publicRef = db.collection("users").document(userID)
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
            try await db.collection("users").document(userID).setData([
                "displayName": displayName,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
            var privateData: [String: Any] = ["updatedAt": FieldValue.serverTimestamp()]
            if let email { privateData["email"] = email }
            try await db.collection("users").document(userID)
                .collection("private").document(privateProfileDocID)
                .setData(privateData, merge: true)
        }
    }

    func updateDisplayName(userID: String, newName: String) async throws {
        try await withRetry { [db] in
            try await db.collection("users").document(userID).setData([
                "displayName": newName,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    func updateSavedListings(userID: String, listingIDs: [String]) async throws {
        try await withRetry { [db] in
            try await db.collection("users").document(userID)
                .collection("private").document(privateProfileDocID)
                .setData([
                    "savedListingIDs": listingIDs,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func updateBlockedUsers(userID: String, blockedUserIDs: [String]) async throws {
        try await withRetry { [db] in
            try await db.collection("users").document(userID)
                .collection("private").document(privateProfileDocID)
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
            _ = try await db.collection("reports").addDocument(data: payload)
        }
    }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        try await withRetry { [db] in
            let snap = try await db.collection("users").document(userID).getDocument()
            guard snap.exists else { return nil }
            return try snap.data(as: UserProfile.self)
        }
    }

    func deleteProfile(userID: String) async throws {
        try await withRetry { [db] in
            // Remove the private subdocument first, then the public doc.
            try await db.collection("users").document(userID)
                .collection("private").document(privateProfileDocID).delete()
            try await db.collection("users").document(userID).delete()
        }
    }

    func updateFCMToken(userID: String, token: String) async throws {
        try await withRetry { [db] in
            try await db.collection("users").document(userID)
                .collection("private").document(privateProfileDocID)
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
        let snap = try await db.collection("users")
            .whereField("displayName", isGreaterThanOrEqualTo: trimmed)
            .whereField("displayName", isLessThan: end)
            .limit(to: 10)
            .getDocuments()
        return snap.documents.compactMap { try? $0.data(as: UserProfile.self) }
    }
}

// MARK: - Friend edges

protocol FriendEdgeRepository: Sendable {
    func listenToEdges(
        userID: String,
        field: String,
        handler: @escaping @Sendable (Result<[FriendEdge], Error>) -> Void
    ) -> RepositoryListener

    func createEdge(_ edge: FriendEdge) async throws
    func updateStatus(edgeID: String, status: FriendStatus) async throws
    func deleteEdge(edgeID: String) async throws
}

struct FirestoreFriendEdgeRepository: FriendEdgeRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToEdges(
        userID: String,
        field: String,
        handler: @escaping @Sendable (Result<[FriendEdge], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection("friendEdges")
            .whereField(field, isEqualTo: userID)
            .limit(to: friendEdgesListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let edges: [FriendEdge] = (snapshot?.documents ?? []).compactMap { doc in
                    do { return try doc.data(as: FriendEdge.self) }
                    catch {
                        repoLog.error("friendEdge decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
                handler(.success(edges))
            }
        return FirestoreListenerBox(reg)
    }

    func createEdge(_ edge: FriendEdge) async throws {
        let edgeID = FriendEdge.edgeID(edge.userA, edge.userB)
        try await withRetry { [db] in
            try db.collection("friendEdges").document(edgeID).setData(from: edge)
        }
    }

    func updateStatus(edgeID: String, status: FriendStatus) async throws {
        try await withRetry { [db] in
            try await db.collection("friendEdges").document(edgeID).updateData([
                "status": status.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func deleteEdge(edgeID: String) async throws {
        try await withRetry { [db] in
            try await db.collection("friendEdges").document(edgeID).delete()
        }
    }
}

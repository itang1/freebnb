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

// MARK: - Homes

protocol HomesRepository: Sendable {
    func listenToListings(
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    func save(_ home: Home) async throws
    func delete(homeID: String) async throws
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
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let homes: [Home] = docs.compactMap { doc in
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

    func save(_ home: Home) async throws {
        try db.collection("homes").document(home.id).setData(from: home)
    }

    func delete(homeID: String) async throws {
        try await db.collection("homes").document(homeID).delete()
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
    func listenToMessages(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Message], Error>) -> Void
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
        // No .order(by:) here — combining whereField with order(by: "createdAt")
        // requires a composite index that may not be deployed. Sort client-side
        // in the store instead; request counts per user are small.
        let reg = db.collection("stayRequests")
            .whereField(field, isEqualTo: userID)
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
        try db.collection("stayRequests").document(request.id).setData(from: request)
    }

    func updateStatus(requestID: String, status: StayRequestStatus, hostNote: String?) async throws {
        var data: [String: Any] = [
            "status": status.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let hostNote { data["hostNote"] = hostNote }
        try await db.collection("stayRequests").document(requestID).updateData(data)
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
    func fetchProfile(userID: String) async throws -> UserProfile?
}

struct FirestoreUserProfileRepository: UserProfileRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToCurrentProfile(
        userID: String,
        handler: @escaping @Sendable (Result<UserProfile?, Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection("users").document(userID)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                guard let snapshot, snapshot.exists else { handler(.success(nil)); return }
                do {
                    let profile = try snapshot.data(as: UserProfile.self)
                    handler(.success(profile))
                } catch {
                    handler(.failure(error))
                }
            }
        return FirestoreListenerBox(reg)
    }

    func createInitialProfile(userID: String, displayName: String, email: String?) async throws {
        var data: [String: Any] = [
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let email { data["email"] = email }
        try await db.collection("users").document(userID).setData(data)
    }

    func updateDisplayName(userID: String, newName: String) async throws {
        try await db.collection("users").document(userID).setData([
            "displayName": newName,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        let snap = try await db.collection("users").document(userID).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: UserProfile.self)
    }
}

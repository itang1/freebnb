//
//  MessagesRepository.swift
//  freebnb
//
//  Direct-message conversations and messages. Split out of the former
//  Repositories.swift (A2).
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

protocol MessagesRepository: Sendable {
    /// Listener for the conversation list. Reads the denormalized
    /// `conversations/{id}` summary docs the `onMessageCreated` trigger
    /// maintains, ordered most-recent first, so no single chatty thread can
    /// evict others (L2). Fetches at most `limit` conversations.
    func listenToConversations(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Conversation], Error>) -> Void
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

    /// Clear the caller's unread count on a conversation (mark read). Writes only
    /// the caller's own entry so rules leave the other participant's count alone.
    func markConversationRead(
        conversationID: String,
        userID: String,
        onError: @escaping @Sendable (Error) -> Void
    )

    /// Add or remove the caller from a conversation's `mutedBy` list.
    func setConversationMuted(
        conversationID: String,
        userID: String,
        muted: Bool,
        onError: @escaping @Sendable (Error) -> Void
    )
}

struct FirestoreMessagesRepository: MessagesRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToConversations(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Conversation], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection(FirestorePaths.conversations)
            .whereField("participants", arrayContains: userID)
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let conversations: [Conversation] = docs.compactMap { doc in
                    guard let conv = Conversation(document: doc.documentID, data: doc.data()) else {
                        Telemetry.decodeFailure(collection: FirestorePaths.conversations, documentID: doc.documentID)
                        return nil
                    }
                    return conv
                }
                handler(.success(conversations))
            }
        return FirestoreListenerBox(reg)
    }

    func markConversationRead(
        conversationID: String,
        userID: String,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        db.collection(FirestorePaths.conversations).document(conversationID).updateData(
            [FieldPath(["unreadCounts", userID]): 0]
        ) { error in if let error { onError(error) } }
    }

    func setConversationMuted(
        conversationID: String,
        userID: String,
        muted: Bool,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        let change = muted
            ? FieldValue.arrayUnion([userID])
            : FieldValue.arrayRemove([userID])
        db.collection(FirestorePaths.conversations).document(conversationID).updateData(
            ["mutedBy": change]
        ) { error in if let error { onError(error) } }
    }

    func listenToConversation(
        participants: [String],
        limit: Int,
        handler: @escaping @Sendable (Result<(messages: [Message], hasMore: Bool), Error>) -> Void
    ) -> RepositoryListener {
        // Fetch limit+1 to detect whether older messages exist.
        let reg = db.collection(FirestorePaths.messages)
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
                        Telemetry.decodeFailure(collection: FirestorePaths.messages, documentID: doc.documentID, error: error)
                        return nil
                    }
                }
                handler(.success((messages, hasMore)))
            }
        return FirestoreListenerBox(reg)
    }

    // Window and per-window cap for the write-path rate limit. Must match the
    // rateLimits rules (windowSeconds()/messageCap()) in firestore.rules and the
    // client-side advisory pre-check in MessageStore.
    private static let rateWindow: TimeInterval = 60

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws {
        // Encode up front so a bad payload throws synchronously (as the old
        // setData(from:) did) rather than inside the transaction.
        let encodedMessage = try Firestore.Encoder().encode(message)
        let db = self.db
        // The message and the sender's rate-limit counter are committed together
        // in one transaction, so firestore.rules can gate the message create on
        // the counter advancing (see rateCounterAdvanced). A transaction has no
        // local-cache echo, so MessageStore shows the message optimistically
        // until the conversation listener delivers the committed copy.
        Task {
            do {
                try await Self.commitRateLimited(db: db, message: message, encodedMessage: encodedMessage)
            } catch {
                onError(error)
            }
        }
    }

    private static func commitRateLimited(
        db: Firestore,
        message: Message,
        encodedMessage: [String: Any]
    ) async throws {
        let rateRef = db.collection(FirestorePaths.rateLimits).document(message.senderUserID)
        let msgRef = db.collection(FirestorePaths.messages).document(message.id)
        try await withRetry {
            _ = try await db.runTransaction { txn, errorPointer -> Any? in
                let snap: DocumentSnapshot
                do {
                    snap = try txn.getDocument(rateRef)
                } catch let error as NSError {
                    errorPointer?.pointee = error
                    return nil
                }

                // Still inside the open window: increment and keep windowStart.
                // Otherwise open a fresh window stamped at the server's write time,
                // which the rules require to equal request.time.
                var counter: [String: Any] = ["windowStart": FieldValue.serverTimestamp(), "count": 1]
                if snap.exists,
                   let windowStart = snap.get("windowStart") as? Timestamp,
                   let count = snap.get("count") as? Int,
                   Date().timeIntervalSince(windowStart.dateValue()) < rateWindow {
                    counter = ["windowStart": windowStart, "count": count + 1]
                }
                txn.setData(counter, forDocument: rateRef)
                txn.setData(encodedMessage, forDocument: msgRef)
                return nil
            }
        }
    }
}

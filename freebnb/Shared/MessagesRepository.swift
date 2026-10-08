//
//  MessagesRepository.swift
//  freebnb
//
//  Direct-message conversations and messages.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

protocol MessagesRepository: Sendable {
    /// Listener for the conversation list: the denormalized `conversations/{id}`
    /// summaries, most recent first, at most `limit`.
    func listenToConversations(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Conversation], Error>) -> Void
    ) -> RepositoryListener

    /// Listener for one thread; `participants` is the sorted pair. Fetches the most
    /// recent `limit` messages and passes `hasMore = true` when a full page arrived.
    func listenToConversation(
        participants: [String],
        limit: Int,
        handler: @escaping @Sendable (Result<(messages: [Message], hasMore: Bool), Error>) -> Void
    ) -> RepositoryListener

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws

    /// Marks read by clearing the caller's own unread count (the rules protect the other's).
    func markConversationRead(
        conversationID: String,
        userID: String,
        onError: @escaping @Sendable (Error) -> Void
    )

    /// Adds or removes the caller from a conversation's `mutedBy` list.
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

    /// How many recent messages to summarize the list from: a message budget, big
    /// enough that a busy thread can't crowd out a quiet one, bounded to avoid downloading a mailbox.
    private static let conversationScanLimit = 500

    /// Builds the thread list from the messages themselves. The `conversations`
    /// summaries come from the `onMessageCreated` Cloud Function, which prod
    /// doesn't deploy (and the create rule is `if false`), so the tab was empty.
    /// The indexed `(participants, timestamp)` query answers it with or without
    /// the trigger, so one path behaves the same everywhere.
    func listenToConversations(
        userID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Conversation], Error>) -> Void
    ) -> RepositoryListener {
        let cache = MessagesSnapshotCache()

        func emit() {
            handler(.success(Self.summarize(
                messages: cache.messages,
                userID: userID,
                limit: limit
            )))
        }

        let reg = db.collection(FirestorePaths.messages)
            .whereField("participants", arrayContains: userID)
            .order(by: "timestamp", descending: true)
            .limit(to: Self.conversationScanLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                cache.messages = (snapshot?.documents ?? []).compactMap { doc in
                    do { return try doc.data(as: Message.self) }
                    catch {
                        Telemetry.decodeFailure(collection: FirestorePaths.messages, documentID: doc.documentID, error: error)
                        return nil
                    }
                }
                emit()
            }

        // Reading or muting changes the list without a message moving, so nudge a redraw.
        let observer = NotificationCenter.default.addObserver(
            forName: ConversationLocalState.didChange,
            object: nil,
            queue: nil
        ) { _ in emit() }

        return CompositeListener(listeners: [
            FirestoreListenerBox(reg),
            NotificationObserverListener(observer: observer)
        ])
    }

    /// Groups messages by counterpart into one summary each, newest first. Unread
    /// is counted as their messages since this device last opened the thread
    /// (everything, on a fresh install).
    static func summarize(
        messages: [Message],
        userID: String,
        limit: Int,
        localState: ConversationLocalState = .shared
    ) -> [Conversation] {
        let lastRead = localState.lastReadDates(userID: userID)
        let muted = localState.mutedIDs(userID: userID)

        let grouped = Dictionary(grouping: messages) {
            MessageStore.conversationID(userIDs: $0.participants)
        }

        return grouped.compactMap { conversationID, msgs -> Conversation? in
            guard let newest = msgs.max(by: {
                ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
            }) else { return nil }

            let readAt = lastRead[conversationID] ?? .distantPast
            let unread = msgs.filter {
                $0.senderUserID != userID && ($0.timestamp ?? .distantPast) > readAt
            }.count

            return Conversation(
                id: conversationID,
                participants: newest.participants,
                lastMessage: ConversationLastMessage(
                    text: newest.text,
                    senderUserID: newest.senderUserID,
                    timestamp: newest.timestamp
                ),
                updatedAt: newest.timestamp,
                unreadCounts: [userID: unread],
                mutedBy: muted.contains(conversationID) ? [userID] : []
            )
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        .prefix(limit)
        .map { $0 }
    }

    func markConversationRead(
        conversationID: String,
        userID: String,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        ConversationLocalState.shared.markRead(conversationID: conversationID, userID: userID)
    }

    func setConversationMuted(
        conversationID: String,
        userID: String,
        muted: Bool,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        ConversationLocalState.shared.setMuted(conversationID: conversationID, userID: userID, muted: muted)
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

    // Window and cap for the write rate limit; must match the rules' windowSeconds()/messageCap() and
    // MessageStore.
    private static let rateWindow: TimeInterval = 60

    func send(_ message: Message, onError: @escaping @Sendable (Error) -> Void) throws {
        // Encode up front so a bad payload throws synchronously, not inside the transaction.
        let encodedMessage = try Firestore.Encoder().encode(message)
        let db = self.db
        // The message and the sender's rate-limit counter commit together so the
        // rules can gate the create on the counter advancing. Transactions have no
        // local echo, so MessageStore shows the message optimistically.
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
        // The counter has two legal shapes and the rules accept the one matching
        // the server's view of the window, but the client guesses with the device
        // clock. A skewed clock or a send near the 60s boundary picks the rejected
        // shape, and permission denied isn't retried, so the send would fail. So
        // on a denial the opposite shape is committed; a genuine rate-limit
        // rejection fails both and still surfaces.
        do {
            try await commitCounter(db: db, message: message, encodedMessage: encodedMessage, invert: false)
        } catch let error as NSError
            where error.domain == firestoreErrorDomain && error.code == permissionDeniedCode {
            try await commitCounter(db: db, message: message, encodedMessage: encodedMessage, invert: true)
        }
    }

    // The domain string `RepositorySupport` keys off; 7 is PERMISSION_DENIED, which `withRetry` won't retry.
    private static let firestoreErrorDomain = "FIRFirestoreErrorDomain"
    private static let permissionDeniedCode = 7

    /// Commits the message and the sender's counter together. `invert` flips the
    /// device-clock guess about whether the window is open, for the retry.
    private static func commitCounter(
        db: Firestore,
        message: Message,
        encodedMessage: [String: Any],
        invert: Bool
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

                // Default to a fresh window stamped at the server's write time (the rules require
                // it equal request.time); also the only legal shape with no counter yet.
                var counter: [String: Any] = ["windowStart": FieldValue.serverTimestamp(), "count": 1]
                if snap.exists,
                   let windowStart = snap.get("windowStart") as? Timestamp,
                   let count = snap.get("count") as? Int {
                    // Increment and keep windowStart while the window is open; `invert` flips this on retry.
                    let deviceSaysOpen = Date().timeIntervalSince(windowStart.dateValue()) < rateWindow
                    if deviceSaysOpen != invert {
                        counter = ["windowStart": windowStart, "count": count + 1]
                    }
                }
                txn.setData(counter, forDocument: rateRef)
                txn.setData(encodedMessage, forDocument: msgRef)
                return nil
            }
        }
    }
}

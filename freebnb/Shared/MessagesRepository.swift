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

    /// How many recent messages to summarize the thread list from. The list shows
    /// one row per correspondent, so this is a message budget, not a row budget:
    /// enough that a busy thread cannot crowd a quiet one off the list, and
    /// bounded so the tab does not download a mailbox to draw a list.
    private static let conversationScanLimit = 500

    /// Builds the thread list out of the messages themselves.
    ///
    /// It used to read `conversations`, a denormalized summary per thread that
    /// `onMessageCreated` maintains. That trigger is a Cloud Function, this
    /// project deploys none, and the collection's create rule is `if false` — so
    /// in production the summaries do not exist, cannot be made, and the Messages
    /// tab listed nothing at all while every thread in it was perfectly readable.
    ///
    /// A participant may read their own messages, and `(participants, timestamp)`
    /// is already indexed for the thread view, so the same query answers "who have
    /// I been talking to" once the rows are grouped by counterpart. That works
    /// with or without the trigger, which is why it replaces the old path outright
    /// rather than falling back to it: one code path that behaves the same in the
    /// emulator and in production beats two that diverge.
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

        // Reading a thread or muting it changes the list without any message
        // moving, so the local state has to be able to nudge a redraw.
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

    /// Groups messages by counterpart into one summary each, newest thread first.
    ///
    /// Unread is counted rather than read off a server-maintained tally: the
    /// messages that arrived from the other person since this device last opened
    /// the thread. A thread never opened on this device counts everything they
    /// sent, which is the right answer for a fresh install.
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
        // The counter has exactly two legal shapes and the rules accept only the
        // one matching the *server's* view of the window. The client has to guess
        // which, and it guesses with the device clock — so a skewed clock, or a
        // message sent within a whisker of the 60s boundary, picks the shape the
        // server rejects. Neither rule branch then matches: the reset branch wants
        // `windowStart == request.time`, the increment branch wants
        // `request.time < windowStart + 60s`. The send fails outright, and because
        // permission denied is not transient, `withRetry` will not rescue it — a
        // device a few minutes slow could not send at all.
        //
        // So the guess is allowed to be wrong once. On a permission denial the
        // opposite shape is committed, which is by construction the other branch.
        // A genuine rate-limit rejection (at the cap, window still open) fails
        // both shapes and still surfaces, which is the behaviour we want to keep.
        do {
            try await commitCounter(db: db, message: message, encodedMessage: encodedMessage, invert: false)
        } catch let error as NSError
            where error.domain == firestoreErrorDomain && error.code == permissionDeniedCode {
            try await commitCounter(db: db, message: message, encodedMessage: encodedMessage, invert: true)
        }
    }

    // Matches the domain string `RepositorySupport` already keys off; 7 is
    // PERMISSION_DENIED, which `withRetry` deliberately treats as non-transient.
    private static let firestoreErrorDomain = "FIRFirestoreErrorDomain"
    private static let permissionDeniedCode = 7

    /// Commits the message and the sender's counter together. `invert` flips the
    /// device-clock guess about whether the window is still open, so the retry
    /// commits the shape the first attempt did not.
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

                // Default to opening a fresh window, stamped at the server's write
                // time, which the rules require to equal request.time. That is also
                // the only legal shape when no counter exists yet.
                var counter: [String: Any] = ["windowStart": FieldValue.serverTimestamp(), "count": 1]
                if snap.exists,
                   let windowStart = snap.get("windowStart") as? Timestamp,
                   let count = snap.get("count") as? Int {
                    // Increment and keep windowStart while the window is still
                    // open. `invert` flips this after the server rejected the
                    // first shape, which means its clock disagreed with ours.
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

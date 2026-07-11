//
//  MessageStore.swift
//  freebnb
//

import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation
import os

struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let senderUserID: String
    let text: String
    @ServerTimestamp var timestamp: Date?
    let participants: [String]  // always sorted [userA, userB]
    /// Present on system messages (stay requested / accepted / declined /
    /// cancelled). When set, the thread renders a structured card instead of the
    /// plain-text bubble (item 29). `text` stays populated with `event.fallbackText`
    /// so the conversation preview, the push body, and clients that predate the
    /// field still read correctly. The Firestore encoder omits it when nil, so an
    /// ordinary chat message never carries the key.
    var event: StayEvent?

    init(
        id: String = UUID().uuidString,
        senderUserID: String,
        text: String,
        timestamp: Date? = nil,
        participants: [String],
        event: StayEvent? = nil
    ) {
        self.id = id
        self.senderUserID = senderUserID
        self.text = text
        self.timestamp = timestamp
        self.participants = participants
        self.event = event
    }
}

/// A structured stay-lifecycle event carried on a system message so the thread
/// can render it as a card rather than an emoji-prefixed string (item 29).
struct StayEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case requested, accepted, declined, cancelled
    }

    let kind: Kind
    /// Human-readable dates for the stay, e.g. "Mar 3 – Mar 6 · 3 nights".
    let dateRange: String
    /// The host's optional note, set only on `accepted`.
    var note: String?

    /// The plain string stored in the message's `text`: the conversation-list
    /// preview, the push body, and what a client that doesn't understand `event`
    /// falls back to. Kept in sync with the card by construction.
    var fallbackText: String {
        var base: String
        switch kind {
        case .requested: base = "Requested to stay · \(dateRange)"
        case .accepted:  base = "Stay accepted · \(dateRange)"
        case .declined:  base = "Stay request declined · \(dateRange)"
        case .cancelled: base = "Request cancelled · \(dateRange)"
        }
        if let note, !note.isEmpty { base += "\n\(note)" }
        return base
    }
}

/// The last message stored on a `conversations/{id}` summary doc.
struct ConversationLastMessage: Hashable, Sendable {
    let text: String
    let senderUserID: String
    let timestamp: Date?
}

/// The denormalized `conversations/{id}` summary maintained by the
/// `onMessageCreated` Cloud Function. The conversation list, unread counts, and
/// mute state all derive from this document (L2/L4) rather than from a global
/// window over recent messages.
struct Conversation: Identifiable, Hashable, Sendable {
    let id: String                    // conversationID = sorted participants joined by "_"
    let participants: [String]
    let lastMessage: ConversationLastMessage
    let updatedAt: Date?
    let unreadCounts: [String: Int]
    let mutedBy: [String]

    /// Parses a Firestore conversation document. Returns nil only when the shape
    /// is unusable (missing participant pair); every other field defaults so a
    /// summary written before mutes/reads exist still decodes.
    init?(document id: String, data: [String: Any]) {
        guard let participants = data["participants"] as? [String],
              participants.count == 2
        else { return nil }

        let lm = data["lastMessage"] as? [String: Any] ?? [:]
        let lastMessage = ConversationLastMessage(
            text: lm["text"] as? String ?? "",
            senderUserID: lm["senderUserID"] as? String ?? "",
            timestamp: (lm["timestamp"] as? Timestamp)?.dateValue()
        )

        var unread: [String: Int] = [:]
        if let raw = data["unreadCounts"] as? [String: Any] {
            for (key, value) in raw {
                if let n = value as? Int { unread[key] = n }
                else if let n = value as? NSNumber { unread[key] = n.intValue }
            }
        }

        self.id = id
        self.participants = participants
        self.lastMessage = lastMessage
        self.updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
        self.unreadCounts = unread
        self.mutedBy = data["mutedBy"] as? [String] ?? []
    }

    // Memberwise init for tests / in-memory construction.
    init(
        id: String,
        participants: [String],
        lastMessage: ConversationLastMessage,
        updatedAt: Date?,
        unreadCounts: [String: Int],
        mutedBy: [String]
    ) {
        self.id = id
        self.participants = participants
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
        self.unreadCounts = unreadCounts
        self.mutedBy = mutedBy
    }
}

struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: String          // conversationID = sorted participants joined by "_"
    let otherUserID: String
    let lastMessage: Message
}

enum MessageState: Hashable {
    case sent
    case pending
    case failed
}

@MainActor
@Observable
final class MessageStore {
    /// True from launch until the conversation-list listener delivers its first
    /// snapshot (or the user turns out to be signed out). Lets the UI show
    /// skeleton rows instead of flashing the "No conversations yet" empty state.
    private(set) var isLoadingConversations = true
    private(set) var pendingIDs: Set<String> = []
    private(set) var failedIDs: Set<String> = []
    /// True when the most recent send was blocked by the client-side rate limit,
    /// so the UI can show a "slow down" notice. Reset on the next allowed send.
    private(set) var isSendRateLimited = false

    // The denormalized conversation summaries the list is built from, keyed by
    // conversationID. Maintained server-side by the onMessageCreated trigger.
    private var conversationDocs: [String: Conversation] = [:]
    // Per-conversation message snapshots opened when a thread is on screen.
    private var threadMessages: [String: [Message]] = [:]
    private var threadHasMore: [String: Bool] = [:]
    private var threadLimits: [String: Int] = [:]
    /// Conversations whose per-thread listener has replied at least once.
    private var threadResolvedIDs: Set<String> = []

    // Optimistic overlays over the server state, cleared once a snapshot catches
    // up. `pendingReadIDs`: conversations the user just opened (unread shown as
    // cleared before the write round-trips). `pendingMuteToggles`: mute/unmute
    // the user just tapped (cid → desired muted state).
    private var pendingReadIDs: Set<String> = []
    private var pendingMuteToggles: [String: Bool] = [:]

    private var failedMessages: [String: Message] = [:]
    // Optimistically-shown sends whose transaction has not yet committed. A
    // rate-limited send commits through a Firestore transaction, which (unlike a
    // plain setData) produces no local-cache echo, so the message would otherwise
    // not appear until the server round-trips. Cleared once the conversation
    // thread listener delivers the committed copy, or moved to `failedMessages`
    // on error. Also drives an optimistic conversation-list entry so a brand-new
    // thread appears before the summary trigger writes its doc.
    private var pendingMessages: [String: Message] = [:]
    private var currentUserID: String?

    @ObservationIgnored private let repository: MessagesRepository
    // `nonisolated(unsafe)` because `deinit` is nonisolated and must tear
    // these down. Both are only assigned from @MainActor contexts, and
    // Firebase's `ListenerRegistration.remove()` and
    // `Auth.removeStateDidChangeListener(_:)` are thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    // Per-conversation listeners; keyed by conversationID. nonisolated(unsafe)
    // for the same reason as activeListener above.
    @ObservationIgnored nonisolated(unsafe) private var threadListeners: [String: RepositoryListener] = [:]
    @ObservationIgnored private let log = AppLog.logger("messaging")
    @ObservationIgnored private let conversationListLimit = 50
    @ObservationIgnored private let threadPageSize = 50
    // Client-side advisory rate limit (30 messages / 60s). A fast-path UX guard
    // that blocks obvious spamming before it reaches Firestore; the real
    // enforcement is in firestore.rules, which gates every message create on the
    // sender's rateLimits counter (see FirestoreMessagesRepository). Keep these
    // values in sync with the rules' messageCap()/windowSeconds().
    @ObservationIgnored private let sendRateLimit = 30
    @ObservationIgnored private let sendRateWindow: TimeInterval = 60
    @ObservationIgnored private var recentSendTimestamps: [Date] = []

    init(repository: MessagesRepository = FirestoreMessagesRepository()) {
        self.repository = repository
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartListener(userID: user?.uid) }
        }
    }

    deinit {
        activeListener?.cancel()
        for (_, listener) in threadListeners { listener.cancel() }
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Conversation ID

    nonisolated static func conversationID(userIDs: [String]) -> String {
        userIDs.sorted().joined(separator: "_")
    }

    // MARK: - Conversation-list listener

    private func restartListener(userID: String?) {
        currentUserID = userID
        activeListener?.cancel()
        activeListener = nil
        for (_, l) in threadListeners { l.cancel() }
        threadListeners = [:]
        guard let userID else {
            conversationDocs = [:]
            threadMessages = [:]
            threadHasMore = [:]
            threadLimits = [:]
            threadResolvedIDs = []
            pendingReadIDs = []
            pendingMuteToggles = [:]
            pendingIDs = []
            failedIDs = []
            failedMessages = [:]
            pendingMessages = [:]
            // Signed out: nothing is coming, so stop showing skeletons.
            isLoadingConversations = false
            return
        }
        isLoadingConversations = true
        activeListener = repository.listenToConversations(userID: userID, limit: conversationListLimit) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyConversations(result: result)
            }
        }
    }

    private func applyConversations(result: Result<[Conversation], Error>) {
        // Either outcome ends the initial load; on failure the empty state is a
        // more honest answer than an indefinite skeleton.
        isLoadingConversations = false
        switch result {
        case .failure(let error):
            log.error("conversations snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let conversations):
            conversationDocs = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            reconcileOptimistic()
        }
    }

    /// Drop optimistic read/mute overlays the server snapshot has now caught up
    /// to, so stale toggles cannot fight a later legitimate change.
    private func reconcileOptimistic() {
        guard let uid = currentUserID else { return }
        for cid in pendingReadIDs where (conversationDocs[cid]?.unreadCounts[uid] ?? 0) == 0 {
            pendingReadIDs.remove(cid)
        }
        for (cid, desired) in pendingMuteToggles {
            let serverMuted = conversationDocs[cid]?.mutedBy.contains(uid) ?? false
            if serverMuted == desired { pendingMuteToggles.removeValue(forKey: cid) }
        }
    }

    // MARK: - Per-conversation listeners (thread view)

    /// Call when a conversation thread appears on screen.
    func openConversation(_ conversationID: String, participants: [String]) {
        guard threadListeners[conversationID] == nil else { return }
        let limit = threadPageSize
        threadLimits[conversationID] = limit
        startThreadListener(conversationID: conversationID, participants: participants, limit: limit)
    }

    /// Call when a conversation thread disappears from screen.
    func closeConversation(_ conversationID: String) {
        threadListeners[conversationID]?.cancel()
        threadListeners.removeValue(forKey: conversationID)
        threadMessages.removeValue(forKey: conversationID)
        threadHasMore.removeValue(forKey: conversationID)
        threadLimits.removeValue(forKey: conversationID)
        threadResolvedIDs.remove(conversationID)
    }

    /// True until the thread's listener has replied at least once.
    ///
    /// Deliberately not a flag flipped on in `openConversation`: the thread view
    /// renders once *before* its `.task` opens the conversation, so such a flag
    /// would read `false` on that first frame and flash the empty state before
    /// the skeleton. Starting from "unresolved" makes the first frame correct.
    ///
    /// Paging in older messages keeps the conversation resolved.
    func isLoadingThread(_ conversationID: String) -> Bool {
        !threadResolvedIDs.contains(conversationID)
    }

    /// Extend the thread by one page. Call when user taps "Load older messages".
    func loadMoreMessages(_ conversationID: String, participants: [String]) {
        guard threadHasMore[conversationID] == true else { return }
        let newLimit = (threadLimits[conversationID] ?? threadPageSize) + threadPageSize
        threadLimits[conversationID] = newLimit
        threadListeners[conversationID]?.cancel()
        startThreadListener(conversationID: conversationID, participants: participants, limit: newLimit)
    }

    func hasMoreMessages(_ conversationID: String) -> Bool {
        threadHasMore[conversationID] ?? false
    }

    private func startThreadListener(conversationID: String, participants: [String], limit: Int) {
        let listener = repository.listenToConversation(participants: participants, limit: limit) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyThread(conversationID: conversationID, result: result)
            }
        }
        threadListeners[conversationID] = listener
    }

    private func applyThread(conversationID: String, result: Result<(messages: [Message], hasMore: Bool), Error>) {
        // Either outcome means the thread's contents are now known.
        threadResolvedIDs.insert(conversationID)
        switch result {
        case .failure(let error):
            log.error("thread snapshot error \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        case .success(let (messages, hasMore)):
            clearOptimistic(delivered: messages)
            threadMessages[conversationID] = messages
            threadHasMore[conversationID] = hasMore
        }
    }

    /// Drops the optimistic and pending-id bookkeeping for messages the server
    /// has now confirmed, so `messages(for:)` shows the committed copy alone.
    private func clearOptimistic(delivered: [Message]) {
        let ids = Set(delivered.map(\.id))
        pendingIDs.subtract(ids)
        for id in ids { pendingMessages.removeValue(forKey: id) }
    }

    // MARK: - Unread tracking

    /// Mark a conversation as read by clearing the caller's server-side unread
    /// count. Optimistically flips the local unread state so the badge updates
    /// before the write round-trips. No-op when there is nothing unread.
    func markRead(conversationID: String) {
        guard let uid = currentUserID,
              (conversationDocs[conversationID]?.unreadCounts[uid] ?? 0) > 0,
              !pendingReadIDs.contains(conversationID)
        else { return }
        pendingReadIDs.insert(conversationID)
        repository.markConversationRead(conversationID: conversationID, userID: uid) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.log.error("markRead \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Let a later snapshot or re-open retry rather than pinning it read.
                self?.pendingReadIDs.remove(conversationID)
            }
        }
    }

    func muteConversation(_ conversationID: String) { setMuted(conversationID, muted: true) }
    func unmuteConversation(_ conversationID: String) { setMuted(conversationID, muted: false) }

    private func setMuted(_ conversationID: String, muted: Bool) {
        guard let uid = currentUserID else { return }
        pendingMuteToggles[conversationID] = muted
        // A summary doc only exists once a thread has at least one message, and
        // rules forbid the client creating one. Muting an empty thread therefore
        // stays purely local until the first message writes the doc.
        guard conversationDocs[conversationID] != nil else { return }
        repository.setConversationMuted(conversationID: conversationID, userID: uid, muted: muted) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.log.error("setMuted \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self?.pendingMuteToggles.removeValue(forKey: conversationID)
            }
        }
    }

    func isMuted(_ conversationID: String) -> Bool {
        if let pending = pendingMuteToggles[conversationID] { return pending }
        guard let uid = currentUserID else { return false }
        return conversationDocs[conversationID]?.mutedBy.contains(uid) ?? false
    }

    /// True when the conversation has unread messages for the caller and is not
    /// muted. Reads the server-maintained unread counter, honouring the local
    /// optimistic read overlay.
    func isUnread(_ conversationID: String, currentUserID: String) -> Bool {
        guard !isMuted(conversationID), !pendingReadIDs.contains(conversationID) else { return false }
        return (conversationDocs[conversationID]?.unreadCounts[currentUserID] ?? 0) > 0
    }

    /// Number of non-muted conversations with unread messages. Matches the APNs
    /// badge the onMessageCreated trigger computes.
    var unreadCount: Int {
        guard let currentUserID else { return 0 }
        return conversationDocs.keys.filter {
            isUnread($0, currentUserID: currentUserID)
        }.count
    }

    // MARK: - Public interface

    var conversationSummaries: [ConversationSummary] {
        guard let currentUserID else { return [] }
        var summaries: [String: ConversationSummary] = [:]

        for (cid, conv) in conversationDocs {
            guard let otherID = conv.participants.first(where: { $0 != currentUserID }) else { continue }
            summaries[cid] = ConversationSummary(
                id: cid,
                otherUserID: otherID,
                lastMessage: Message(
                    id: "",
                    senderUserID: conv.lastMessage.senderUserID,
                    text: conv.lastMessage.text,
                    timestamp: conv.lastMessage.timestamp,
                    participants: conv.participants
                )
            )
        }

        // Overlay optimistic sends the summary trigger has not yet reflected, so
        // a just-sent message (or a brand-new thread) shows immediately.
        for pending in pendingMessages.values {
            let cid = MessageStore.conversationID(userIDs: pending.participants)
            let existingKey = summaries[cid].map { Self.sortKey($0.lastMessage) } ?? .distantPast
            guard Self.sortKey(pending) >= existingKey,
                  let otherID = pending.participants.first(where: { $0 != currentUserID })
            else { continue }
            summaries[cid] = ConversationSummary(id: cid, otherUserID: otherID, lastMessage: pending)
        }

        return summaries.values.sorted { Self.sortKey($0.lastMessage) > Self.sortKey($1.lastMessage) }
    }

    func messages(for conversationID: String) -> [Message] {
        let sent = threadMessages[conversationID] ?? []
        // Once the committed copy has arrived it wins, so drop any optimistic or
        // failed entry sharing its id to avoid showing the message twice.
        let sentIDs = Set(sent.map(\.id))
        func inConversation(_ m: Message) -> Bool {
            MessageStore.conversationID(userIDs: m.participants) == conversationID
                && !sentIDs.contains(m.id)
        }
        let pending = pendingMessages.values.filter(inConversation)
        let failed = failedMessages.values.filter(inConversation)
        return (sent + pending + failed).sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    func state(of messageID: String) -> MessageState {
        if failedIDs.contains(messageID) { return .failed }
        if pendingIDs.contains(messageID) { return .pending }
        return .sent
    }

    // Pending messages (server timestamp not yet resolved) sort to the end.
    private static func sortKey(_ m: Message) -> Date {
        m.timestamp ?? .distantFuture
    }

    /// Send a structured stay event (item 29). The card the thread renders and the
    /// `text` the list/push fall back to are produced from the one `StayEvent`, so
    /// they can never drift.
    @discardableResult
    func sendStayEvent(_ event: StayEvent, senderUserID: String, recipientUserID: String) -> Bool {
        send(text: event.fallbackText, senderUserID: senderUserID, recipientUserID: recipientUserID, event: event)
    }

    @discardableResult
    func send(text: String, senderUserID: String, recipientUserID: String, event: StayEvent? = nil) -> Bool {
        guard senderUserID != recipientUserID,
              !senderUserID.isEmpty, !recipientUserID.isEmpty
        else { return false }

        // Advisory client-side rate limit; blocks obvious spamming before it
        // reaches Firestore. firestore.rules is the server-side counterpart.
        if isOverSendRateLimit() {
            isSendRateLimited = true
            log.error("send blocked: client rate limit of \(self.sendRateLimit) per \(Int(self.sendRateWindow))s reached")
            return false
        }
        isSendRateLimited = false
        recentSendTimestamps.append(Date())

        let participants = [senderUserID, recipientUserID].sorted()
        let msg = Message(
            senderUserID: senderUserID,
            text: text,
            timestamp: nil,
            participants: participants,
            event: event
        )
        pendingIDs.insert(msg.id)
        // Show the message immediately. The stored timestamp is a client stamp so
        // it sorts to the end of the thread; the committed copy (server timestamp)
        // replaces it when the listener delivers it.
        var optimistic = msg
        optimistic.timestamp = Date()
        pendingMessages[msg.id] = optimistic
        do {
            try repository.send(msg) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.markFailed(msg: msg, error: error)
                }
            }
        } catch {
            markFailed(msg: msg, error: error)
            return false
        }
        return true
    }

    private func isOverSendRateLimit() -> Bool {
        let cutoff = Date().addingTimeInterval(-sendRateWindow)
        recentSendTimestamps.removeAll { $0 < cutoff }
        return recentSendTimestamps.count >= sendRateLimit
    }

    func retry(_ messageID: String) {
        guard let failed = failedMessages.removeValue(forKey: messageID) else { return }
        failedIDs.remove(messageID)
        let recipient = failed.participants.first { $0 != failed.senderUserID } ?? ""
        _ = send(text: failed.text, senderUserID: failed.senderUserID, recipientUserID: recipient, event: failed.event)
    }

    func discardFailed(_ messageID: String) {
        failedIDs.remove(messageID)
        failedMessages.removeValue(forKey: messageID)
    }

    private func markFailed(msg: Message, error: Error) {
        log.error("write error \(msg.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        pendingIDs.remove(msg.id)
        pendingMessages.removeValue(forKey: msg.id)
        failedIDs.insert(msg.id)
        var stamped = msg
        stamped.timestamp = Date()
        failedMessages[msg.id] = stamped
    }
}

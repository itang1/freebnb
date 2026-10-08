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
    /// Present on system messages (stay requested / accepted / etc.); the thread
    /// renders a card instead of a bubble. `text` carries `event.fallbackText`
    /// for previews, pushes and older clients. Omitted from the encoding when nil.
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

/// A structured stay-lifecycle event on a system message, rendered as a card.
struct StayEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `offered` is the host-initiated mirror of `requested`.
        case requested, offered, accepted, declined, cancelled, modified
        /// A host calling off a stay the guest was already given. Kept apart from
        /// `cancelled` so the card can offer a way back to the listing's other dates.
        case hostCancelled
    }

    let kind: Kind
    /// Human-readable dates for the stay, e.g. "Mar 3 – Mar 6 · 3 nights".
    let dateRange: String
    /// The host's optional note, set on `accepted` and `hostCancelled`.
    var note: String?
    /// The listing, carried only on `hostCancelled` so the card can link back to its availability.
    var listingID: String?

    /// The plain string stored in `text`: list preview, push body and fallback for older clients.
    var fallbackText: String {
        var base: String
        switch kind {
        case .requested: base = "Requested to stay · \(dateRange)"
        case .offered:   base = "Offered their place · \(dateRange)"
        case .accepted:  base = "Stay accepted · \(dateRange)"
        case .declined:  base = "Stay request declined · \(dateRange)"
        case .cancelled: base = "Request cancelled · \(dateRange)"
        case .hostCancelled: base = "Stay cancelled · \(dateRange)"
        case .modified:  base = "Dates changed · \(dateRange)"
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
/// `onMessageCreated` Cloud Function; the list, unread counts and mutes derive from it.
struct Conversation: Identifiable, Hashable, Sendable {
    let id: String                    // conversationID = sorted participants joined by "_"
    let participants: [String]
    let lastMessage: ConversationLastMessage
    let updatedAt: Date?
    let unreadCounts: [String: Int]
    let mutedBy: [String]

    /// Parses a conversation document. Nil only when the participant pair is
    /// missing; other fields default so older summaries still decode.
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

    // Memberwise init for tests and in-memory construction.
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
    /// True from launch until the first list snapshot (or sign-out), so the UI shows skeletons, not the empty state.
    private(set) var isLoadingConversations = true
    private(set) var pendingIDs: Set<String> = []
    private(set) var failedIDs: Set<String> = []
    /// True when the last send hit the client-side rate limit; reset on the next allowed send.
    private(set) var isSendRateLimited = false

    /// The conversation list, newest first, rebuilt by `rebuildConversationSummaries()`
    /// whenever its inputs change. Stored so the list's repeated reads are cheap.
    private(set) var conversationSummaries: [ConversationSummary] = []

    // Server-maintained conversation summaries, keyed by conversationID.
    private var conversationDocs: [String: Conversation] = [:]
    // Per-conversation message snapshots for threads on screen.
    private var threadMessages: [String: [Message]] = [:]
    private var threadHasMore: [String: Bool] = [:]
    private var threadLimits: [String: Int] = [:]
    /// Conversations whose per-thread listener has replied at least once.
    private var threadResolvedIDs: Set<String> = []

    // Optimistic overlays cleared once a snapshot catches up: `pendingReadIDs`
    // (just-opened conversations) and `pendingMuteToggles` (cid → desired muted state).
    private var pendingReadIDs: Set<String> = []
    private var pendingMuteToggles: [String: Bool] = [:]

    private var failedMessages: [String: Message] = [:]
    // Optimistic sends whose transaction hasn't committed (transactions produce no
    // local echo). Cleared when the thread listener delivers the copy, or moved to
    // `failedMessages` on error; also drives an optimistic list entry for new threads.
    private var pendingMessages: [String: Message] = [:]
    private var currentUserID: String?

    @ObservationIgnored private let repository: MessagesRepository
    // `nonisolated(unsafe)`: deinit is nonisolated but must tear these down; both are thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    // Per-conversation listeners keyed by conversationID.
    @ObservationIgnored nonisolated(unsafe) private var threadListeners: [String: RepositoryListener] = [:]
    @ObservationIgnored private let log = AppLog.logger("messaging")
    @ObservationIgnored private let conversationListLimit = 50
    @ObservationIgnored private let threadPageSize = 50
    // Advisory client rate limit (30 messages / 60s). The real limit is in
    // firestore.rules; keep the values in sync with messageCap()/windowSeconds().
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
        let previousUserID = currentUserID
        currentUserID = userID
        rebuildConversationSummaries()
        activeListener?.cancel()
        activeListener = nil
        for (_, l) in threadListeners { l.cancel() }
        threadListeners = [:]
        guard let userID else {
            // Read/mute state is on-device, so drop it or the next account inherits the badges and mutes.
            if let previousUserID {
                ConversationLocalState.shared.clear(userID: previousUserID)
            }
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
            rebuildConversationSummaries()
            // Signed out: stop showing skeletons.
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
        // Either outcome ends the initial load; an empty state beats an endless skeleton.
        isLoadingConversations = false
        switch result {
        case .failure(let error):
            log.error("conversations snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let conversations):
            conversationDocs = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            reconcileOptimistic()
            rebuildConversationSummaries()
        }
    }

    /// Drops optimistic read/mute overlays the server has caught up to.
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

    /// True until the thread's listener has replied once. Not a flag set in
    /// `openConversation`: the view renders once before its `.task` runs, which
    /// would flash the empty state. Paging in older messages keeps it resolved.
    func isLoadingThread(_ conversationID: String) -> Bool {
        !threadResolvedIDs.contains(conversationID)
    }

    /// Extends the thread by one page ("Load older messages").
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
        // Either outcome means the thread's contents are known.
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

    /// Drops optimistic and pending bookkeeping for messages the server confirmed.
    private func clearOptimistic(delivered: [Message]) {
        let ids = Set(delivered.map(\.id))
        pendingIDs.subtract(ids)
        // Rebuild only when an entry went away; most snapshots clear nothing.
        var clearedAny = false
        for id in ids where pendingMessages.removeValue(forKey: id) != nil {
            clearedAny = true
        }
        if clearedAny { rebuildConversationSummaries() }
    }

    // MARK: - Unread tracking

    /// Marks a conversation read by clearing the server-side unread count,
    /// flipping the local state first. No-op when nothing is unread.
    func markRead(conversationID: String) {
        guard let uid = currentUserID,
              (conversationDocs[conversationID]?.unreadCounts[uid] ?? 0) > 0,
              !pendingReadIDs.contains(conversationID)
        else { return }
        pendingReadIDs.insert(conversationID)
        repository.markConversationRead(conversationID: conversationID, userID: uid) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.log.error("markRead \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Let a later snapshot or re-open retry.
                self?.pendingReadIDs.remove(conversationID)
            }
        }
    }

    func muteConversation(_ conversationID: String) { setMuted(conversationID, muted: true) }
    func unmuteConversation(_ conversationID: String) { setMuted(conversationID, muted: false) }

    private func setMuted(_ conversationID: String, muted: Bool) {
        guard let uid = currentUserID else { return }
        pendingMuteToggles[conversationID] = muted
        // The summary doc exists only after the first message and rules forbid the
        // client creating it, so muting an empty thread stays local until then.
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

    /// True when the conversation has unread messages and isn't muted.
    func isUnread(_ conversationID: String, currentUserID: String) -> Bool {
        guard !isMuted(conversationID), !pendingReadIDs.contains(conversationID) else { return false }
        return (conversationDocs[conversationID]?.unreadCounts[currentUserID] ?? 0) > 0
    }

    /// Number of unmuted conversations with unread messages; matches the APNs badge.
    var unreadCount: Int {
        guard let currentUserID else { return 0 }
        return conversationDocs.keys.filter {
            isUnread($0, currentUserID: currentUserID)
        }.count
    }

    // MARK: - Public interface

    /// True once a thread with `otherUserID` exists (including an unechoed optimistic send).
    func hasConversation(with otherUserID: String) -> Bool {
        guard let currentUserID else { return false }
        let cid = MessageStore.conversationID(userIDs: [currentUserID, otherUserID])
        if conversationDocs[cid] != nil { return true }
        return pendingMessages.values.contains {
            Set($0.participants) == Set([currentUserID, otherUserID])
        }
    }

    /// Rebuilds `conversationSummaries` from the server docs and optimistic
    /// overlay. Called when inputs change rather than on every read.
    private func rebuildConversationSummaries() {
        guard let currentUserID else {
            conversationSummaries = []
            return
        }
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

        // Overlay optimistic sends the trigger hasn't reflected yet.
        for pending in pendingMessages.values {
            let cid = MessageStore.conversationID(userIDs: pending.participants)
            let existingKey = summaries[cid].map { Self.sortKey($0.lastMessage) } ?? .distantPast
            guard Self.sortKey(pending) >= existingKey,
                  let otherID = pending.participants.first(where: { $0 != currentUserID })
            else { continue }
            summaries[cid] = ConversationSummary(id: cid, otherUserID: otherID, lastMessage: pending)
        }

        conversationSummaries = summaries.values
            .sorted { Self.sortKey($0.lastMessage) > Self.sortKey($1.lastMessage) }
    }

    func messages(for conversationID: String) -> [Message] {
        let sent = threadMessages[conversationID] ?? []
        // Once the committed copy arrives it wins; drop optimistic or failed entries with its id.
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

    /// Sends a structured stay event; the card and its `text` fallback both come from the one `StayEvent`.
    @discardableResult
    func sendStayEvent(_ event: StayEvent, senderUserID: String, recipientUserID: String) -> Bool {
        send(text: event.fallbackText, senderUserID: senderUserID, recipientUserID: recipientUserID, event: event)
    }

    @discardableResult
    func send(text: String, senderUserID: String, recipientUserID: String, event: StayEvent? = nil) -> Bool {
        guard senderUserID != recipientUserID,
              !senderUserID.isEmpty, !recipientUserID.isEmpty
        else { return false }

        // Advisory rate limit; firestore.rules is the server-side counterpart.
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
        // Show the message immediately with a client stamp; the committed copy replaces it.
        var optimistic = msg
        optimistic.timestamp = Date()
        pendingMessages[msg.id] = optimistic
        rebuildConversationSummaries()
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
        rebuildConversationSummaries()
        failedIDs.insert(msg.id)
        var stamped = msg
        stamped.timestamp = Date()
        failedMessages[msg.id] = stamped
    }
}

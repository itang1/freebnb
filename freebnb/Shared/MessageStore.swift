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

    init(
        id: String = UUID().uuidString,
        senderUserID: String,
        text: String,
        timestamp: Date? = nil,
        participants: [String]
    ) {
        self.id = id
        self.senderUserID = senderUserID
        self.text = text
        self.timestamp = timestamp
        self.participants = participants
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
    private(set) var mutedConversationIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: UserDefaultsKey.mutedConversationIDs) ?? [])
    }()

    // Global snapshot: last few messages across all conversations (for summaries).
    private var conversations: [String: [Message]] = [:]
    // Per-conversation snapshots opened when a thread is on screen.
    private var threadMessages: [String: [Message]] = [:]
    private var threadHasMore: [String: Bool] = [:]
    private var threadLimits: [String: Int] = [:]
    /// Conversations whose per-thread listener has replied at least once.
    private var threadResolvedIDs: Set<String> = []

    private var failedMessages: [String: Message] = [:]
    // Optimistically-shown sends whose transaction has not yet committed. A
    // rate-limited send commits through a Firestore transaction, which (unlike a
    // plain setData) produces no local-cache echo, so the message would otherwise
    // not appear until the server round-trips. Cleared once the conversation
    // listener delivers the committed copy, or moved to `failedMessages` on error.
    private var pendingMessages: [String: Message] = [:]
    private var currentUserID: String?
    /// Last-read message ID per conversation, persisted across launches.
    private var lastReadIDs: [String: String] = {
        UserDefaults.standard.dictionary(forKey: UserDefaultsKey.lastReadMessageIDs) as? [String: String] ?? [:]
    }()

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
    @ObservationIgnored private let summaryLimit = 50
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

    // MARK: - Global listener (conversation list)

    private func restartListener(userID: String?) {
        currentUserID = userID
        activeListener?.cancel()
        activeListener = nil
        for (_, l) in threadListeners { l.cancel() }
        threadListeners = [:]
        guard let userID else {
            conversations = [:]
            threadMessages = [:]
            threadHasMore = [:]
            threadLimits = [:]
            threadResolvedIDs = []
            pendingIDs = []
            failedIDs = []
            failedMessages = [:]
            pendingMessages = [:]
            // Signed out: nothing is coming, so stop showing skeletons.
            isLoadingConversations = false
            return
        }
        isLoadingConversations = true
        activeListener = repository.listenToMessages(userID: userID, limit: summaryLimit) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyGlobal(result: result)
            }
        }
    }

    private func applyGlobal(result: Result<[Message], Error>) {
        // Either outcome ends the initial load; on failure the empty state is a
        // more honest answer than an indefinite skeleton.
        isLoadingConversations = false
        switch result {
        case .failure(let error):
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let all):
            clearOptimistic(delivered: all)
            conversations = Dictionary(grouping: all) {
                MessageStore.conversationID(userIDs: $0.participants)
            }
        }
    }

    /// Drops the optimistic and pending-id bookkeeping for messages the server
    /// has now confirmed, so `messages(for:)` shows the committed copy alone.
    private func clearOptimistic(delivered: [Message]) {
        let ids = Set(delivered.map(\.id))
        pendingIDs.subtract(ids)
        for id in ids { pendingMessages.removeValue(forKey: id) }
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

    /// True until we know what the thread contains: its listener has not replied
    /// yet and the global listener has nothing for it either.
    ///
    /// Deliberately not a flag flipped on in `openConversation`: the thread view
    /// renders once *before* its `.task` opens the conversation, so such a flag
    /// would read `false` on that first frame and flash the empty state before
    /// the skeleton. Starting from "unresolved" makes the first frame correct.
    ///
    /// Paging in older messages keeps the conversation resolved.
    func isLoadingThread(_ conversationID: String) -> Bool {
        !threadResolvedIDs.contains(conversationID) && conversations[conversationID] == nil
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
        // Either outcome means the thread's contents are now known. On failure the
        // global snapshot (if any) still shows through `messages(for:)`, so the
        // thread resolves to whatever is already on hand rather than a skeleton.
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

    // MARK: - Unread tracking

    /// Mark the latest message in a conversation as read.
    func markRead(conversationID: String) {
        let msgs = threadMessages[conversationID] ?? conversations[conversationID] ?? []
        guard let last = msgs.max(by: { Self.sortKey($0) < Self.sortKey($1) }) else { return }
        lastReadIDs[conversationID] = last.id
        UserDefaults.standard.set(lastReadIDs, forKey: UserDefaultsKey.lastReadMessageIDs)
    }

    func muteConversation(_ conversationID: String) {
        mutedConversationIDs.insert(conversationID)
        UserDefaults.standard.set(Array(mutedConversationIDs), forKey: UserDefaultsKey.mutedConversationIDs)
    }

    func unmuteConversation(_ conversationID: String) {
        mutedConversationIDs.remove(conversationID)
        UserDefaults.standard.set(Array(mutedConversationIDs), forKey: UserDefaultsKey.mutedConversationIDs)
    }

    func isMuted(_ conversationID: String) -> Bool {
        mutedConversationIDs.contains(conversationID)
    }

    /// True when the other user sent the last message and it hasn't been read.
    /// Muted conversations are never considered unread (no badge, no dot).
    func isUnread(_ conversationID: String, currentUserID: String) -> Bool {
        guard !mutedConversationIDs.contains(conversationID),
              let summary = conversationSummaries.first(where: { $0.id == conversationID })
        else { return false }
        return summary.lastMessage.senderUserID != currentUserID &&
               lastReadIDs[conversationID] != summary.lastMessage.id
    }

    /// Number of conversations where the last message is from someone else,
    /// hasn't been seen yet, and is not muted.
    var unreadCount: Int {
        guard let currentUserID else { return 0 }
        return conversationSummaries.filter { summary in
            isUnread(summary.id, currentUserID: currentUserID)
        }.count
    }

    // MARK: - Public interface

    var conversationSummaries: [ConversationSummary] {
        guard let currentUserID else { return [] }
        // Merge global and thread data; thread data wins for conversations that are open.
        var merged = conversations
        for (cid, msgs) in threadMessages { merged[cid] = msgs }
        return merged
            .compactMap { cid, messages -> ConversationSummary? in
                guard let last = messages.max(by: { Self.sortKey($0) < Self.sortKey($1) }),
                      let otherID = last.participants.first(where: { $0 != currentUserID })
                else { return nil }
                return ConversationSummary(id: cid, otherUserID: otherID, lastMessage: last)
            }
            .sorted { Self.sortKey($0.lastMessage) > Self.sortKey($1.lastMessage) }
    }

    func messages(for conversationID: String) -> [Message] {
        // Prefer the per-conversation snapshot (more complete) when available.
        let sent = threadMessages[conversationID] ?? conversations[conversationID] ?? []
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

    @discardableResult
    func send(text: String, senderUserID: String, recipientUserID: String) -> Bool {
        guard senderUserID != recipientUserID,
              !senderUserID.isEmpty, !recipientUserID.isEmpty
        else { return false }

        // Advisory client-side rate limit; blocks obvious spamming before it
        // reaches Firestore. The callable below is the server-side counterpart.
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
            participants: participants
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
        _ = send(text: failed.text, senderUserID: failed.senderUserID, recipientUserID: recipient)
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

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
    private(set) var pendingIDs: Set<String> = []
    private(set) var failedIDs: Set<String> = []

    // Global snapshot: last few messages across all conversations (for summaries).
    private var conversations: [String: [Message]] = [:]
    // Per-conversation snapshots opened when a thread is on screen.
    private var threadMessages: [String: [Message]] = [:]
    private var threadHasMore: [String: Bool] = [:]
    private var threadLimits: [String: Int] = [:]

    private var failedMessages: [String: Message] = [:]
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

    static func conversationID(userIDs: [String]) -> String {
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
            pendingIDs = []
            failedIDs = []
            failedMessages = [:]
            return
        }
        activeListener = repository.listenToMessages(userID: userID, limit: summaryLimit) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyGlobal(result: result)
            }
        }
    }

    private func applyGlobal(result: Result<[Message], Error>) {
        switch result {
        case .failure(let error):
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let all):
            pendingIDs.subtract(Set(all.map { $0.id }))
            conversations = Dictionary(grouping: all) {
                MessageStore.conversationID(userIDs: $0.participants)
            }
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
        switch result {
        case .failure(let error):
            log.error("thread snapshot error \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        case .success(let (messages, hasMore)):
            pendingIDs.subtract(Set(messages.map { $0.id }))
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

    /// Number of conversations where the last message is from someone else
    /// and hasn't been seen yet.
    var unreadCount: Int {
        guard let currentUserID else { return 0 }
        return conversationSummaries.filter { summary in
            summary.lastMessage.senderUserID != currentUserID &&
            lastReadIDs[summary.id] != summary.lastMessage.id
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
        let failed = failedMessages.values.filter {
            MessageStore.conversationID(userIDs: $0.participants) == conversationID
        }
        return (sent + failed).sorted { Self.sortKey($0) < Self.sortKey($1) }
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
        let participants = [senderUserID, recipientUserID].sorted()
        let msg = Message(
            senderUserID: senderUserID,
            text: text,
            timestamp: nil,
            participants: participants
        )
        pendingIDs.insert(msg.id)
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
        failedIDs.insert(msg.id)
        var stamped = msg
        stamped.timestamp = Date()
        failedMessages[msg.id] = stamped
    }
}

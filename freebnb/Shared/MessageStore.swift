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

    private var conversations: [String: [Message]] = [:]
    private var failedMessages: [String: Message] = [:]
    private var currentUserID: String?

    @ObservationIgnored private let repository: MessagesRepository
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let log = AppLog.logger("messaging")
    @ObservationIgnored private let historyLimit = 200

    init(repository: MessagesRepository = FirestoreMessagesRepository()) {
        self.repository = repository
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartListener(userID: user?.uid) }
        }
    }

    deinit {
        activeListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Conversation ID

    static func conversationID(userIDs: [String]) -> String {
        userIDs.sorted().joined(separator: "_")
    }

    // MARK: - Listener

    private func restartListener(userID: String?) {
        currentUserID = userID
        activeListener?.cancel()
        activeListener = nil
        guard let userID else {
            conversations = [:]
            pendingIDs = []
            failedIDs = []
            failedMessages = [:]
            return
        }
        activeListener = repository.listenToMessages(userID: userID, limit: historyLimit) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.apply(result: result)
            }
        }
    }

    private func apply(result: Result<[Message], Error>) {
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

    // MARK: - Public interface

    var conversationSummaries: [ConversationSummary] {
        guard let currentUserID else { return [] }
        return conversations
            .compactMap { cid, messages -> ConversationSummary? in
                guard let last = messages.max(by: { Self.sortKey($0) < Self.sortKey($1) }),
                      let otherID = last.participants.first(where: { $0 != currentUserID })
                else { return nil }
                return ConversationSummary(id: cid, otherUserID: otherID, lastMessage: last)
            }
            .sorted { Self.sortKey($0.lastMessage) > Self.sortKey($1.lastMessage) }
    }

    func messages(for conversationID: String) -> [Message] {
        let sent = conversations[conversationID] ?? []
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

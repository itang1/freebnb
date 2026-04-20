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
    var id: String = UUID().uuidString
    let senderUserID: String
    let text: String
    @ServerTimestamp var timestamp: Date?
    let participants: [String]  // always sorted [userA, userB]
}

struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: String          // conversationID = sorted participants joined by "_"
    let otherUserID: String
    let lastMessage: Message
}

@MainActor
@Observable
final class MessageStore {
    private(set) var pendingIDs: Set<String> = []

    private var conversations: [String: [Message]] = [:]
    private var currentUserID: String?
    // Firebase handles are thread-safe to release; keep them reachable from deinit.
    @ObservationIgnored nonisolated(unsafe) private var listener: ListenerRegistration?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let db = Firestore.firestore()
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "messaging")

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartListener(userID: user?.uid) }
        }
    }

    deinit {
        listener?.remove()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Conversation ID

    static func conversationID(userIDs: [String]) -> String {
        userIDs.sorted().joined(separator: "_")
    }

    // MARK: - Listener

    private func restartListener(userID: String?) {
        currentUserID = userID
        listener?.remove()
        listener = nil
        guard let userID else {
            conversations = [:]
            pendingIDs = []
            return
        }
        listener = db.collection("messages")
            .whereField("participants", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    self?.apply(snapshot: snapshot, error: error)
                }
            }
    }

    private func apply(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
            return
        }
        let all = (snapshot?.documents ?? []).compactMap { doc -> Message? in
            do { return try doc.data(as: Message.self) }
            catch {
                log.error("decode error \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        pendingIDs.subtract(Set(all.map { $0.id }))
        conversations = Dictionary(grouping: all) {
            MessageStore.conversationID(userIDs: $0.participants)
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
        (conversations[conversationID] ?? []).sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    func isPending(_ messageID: String) -> Bool {
        pendingIDs.contains(messageID)
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
            timestamp: nil,       // Firestore fills via @ServerTimestamp
            participants: participants
        )
        pendingIDs.insert(msg.id)
        let ref = db.collection("messages").document(msg.id)
        do {
            try ref.setData(from: msg) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.log.error("write error: \(error.localizedDescription, privacy: .public)")
                    self?.pendingIDs.remove(msg.id)
                }
            }
        } catch {
            log.error("encode error: \(error.localizedDescription, privacy: .public)")
            pendingIDs.remove(msg.id)
            return false
        }
        return true
    }
}

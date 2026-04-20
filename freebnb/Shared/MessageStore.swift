//
//  MessageStore.swift
//  freebnb
//

import FirebaseAuth
import FirebaseFirestore
import Foundation

struct Message: Identifiable, Codable {
    var id: String = UUID().uuidString
    let senderUserID: String
    let text: String
    @ServerTimestamp var timestamp: Date?
    let participants: [String]  // always sorted [userA, userB]
}

struct ConversationSummary: Identifiable {
    let id: String          // conversationID = sorted participants joined by "_"
    let otherUserID: String
    let lastMessage: Message
}

class MessageStore: ObservableObject {
    @Published private var conversations: [String: [Message]] = [:]
    @Published private(set) var pendingIDs: Set<String> = []

    private var currentUserID: String?
    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private let db = Firestore.firestore()

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.restartListener(userID: user?.uid)
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
            DispatchQueue.main.async {
                self.conversations = [:]
                self.pendingIDs = []
            }
            return
        }
        listener = db.collection("messages")
            .whereField("participants", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let error {
                        print("MessageStore error: \(error)")
                        return
                    }
                    let all = (snapshot?.documents ?? []).compactMap { doc -> Message? in
                        do { return try doc.data(as: Message.self) }
                        catch { print("MessageStore decode error \(doc.documentID): \(error)"); return nil }
                    }
                    self.pendingIDs.subtract(Set(all.map { $0.id }))
                    self.conversations = Dictionary(grouping: all) {
                        MessageStore.conversationID(userIDs: $0.participants)
                    }
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
        (conversations[conversationID] ?? []).sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    func isPending(_ messageID: String) -> Bool {
        pendingIDs.contains(messageID)
    }

    // Pending messages (server timestamp not yet resolved) sort to the end.
    private static func sortKey(_ m: Message) -> Date {
        m.timestamp ?? .distantFuture
    }

    // Returns false if the write cannot be attempted. Caller should not clear the draft.
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
        do {
            try db.collection("messages").document(msg.id).setData(from: msg) { [weak self] error in
                if let error {
                    print("MessageStore write error: \(error)")
                    DispatchQueue.main.async { self?.pendingIDs.remove(msg.id) }
                }
            }
        } catch {
            print("MessageStore encode error: \(error)")
            pendingIDs.remove(msg.id)
            return false
        }
        return true
    }
}

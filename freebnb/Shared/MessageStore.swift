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
    let timestamp: Date
    let homeID: String
    let participants: [String]
}

class MessageStore: ObservableObject {
    @Published private var conversations: [String: [Message]] = [:]

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

    // MARK: - Listener

    private func restartListener(userID: String?) {
        listener?.remove()
        listener = nil
        guard let userID else {
            DispatchQueue.main.async { self.conversations = [:] }
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
                    let all = (snapshot?.documents ?? []).compactMap { self.decode($0) }
                    self.conversations = Dictionary(grouping: all) { $0.homeID }
                }
            }
    }

    // MARK: - Public interface

    func messages(for homeID: String) -> [Message] {
        (conversations[homeID] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    func hasMessages(for homeID: String) -> Bool {
        !(conversations[homeID]?.isEmpty ?? true)
    }

    func send(text: String, to homeID: String, senderUserID: String, participants: [String]) {
        let msg = Message(
            senderUserID: senderUserID,
            text: text,
            timestamp: Date(),
            homeID: homeID,
            participants: participants
        )
        guard let data = encoded(msg) else {
            print("MessageStore: failed to encode message")
            return
        }
        db.collection("messages").document(msg.id).setData(data) { error in
            if let error { print("MessageStore write error: \(error)") }
        }
    }

    // MARK: - Codable helpers

    private func decode(_ document: QueryDocumentSnapshot) -> Message? {
        var data = document.data()
        data["id"] = document.documentID
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let msg = try? JSONDecoder().decode(Message.self, from: jsonData)
        else { return nil }
        return msg
    }

    private func encoded(_ msg: Message) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(msg),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
}

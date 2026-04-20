//
//  MessageStore.swift
//  freebnb
//

import Foundation

struct Message: Identifiable {
    let id = UUID()
    let senderUserID: String
    let text: String
    let timestamp: Date
}

class MessageStore: ObservableObject {
    @Published private var conversations: [String: [Message]] = [:]

    func messages(for homeID: String) -> [Message] {
        conversations[homeID] ?? []
    }

    func hasMessages(for homeID: String) -> Bool {
        !(conversations[homeID]?.isEmpty ?? true)
    }

    func send(text: String, to homeID: String, senderUserID: String) {
        let msg = Message(senderUserID: senderUserID, text: text, timestamp: Date())
        conversations[homeID, default: []].append(msg)
    }
}

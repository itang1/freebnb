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
    @Published private var conversations: [UUID: [Message]] = [:]

    func messages(for homeID: UUID) -> [Message] {
        conversations[homeID] ?? []
    }

    func hasMessages(for homeID: UUID) -> Bool {
        !(conversations[homeID]?.isEmpty ?? true)
    }

    func send(text: String, to homeID: UUID, senderUserID: String) {
        let msg = Message(senderUserID: senderUserID, text: text, timestamp: Date())
        conversations[homeID, default: []].append(msg)
    }
}

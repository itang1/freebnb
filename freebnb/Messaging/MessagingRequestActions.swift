//
//  MessagingRequestActions.swift
//  freebnb
//
//  Accept / decline / cancel from inside a chat thread. Each action mutates the
//  request and then posts the matching system message into the conversation, so
//  the two always travel together. Split out of MessagingPage.swift (A2).
//

import Foundation

/// The struct itself is nonisolated so a view can build one in a computed
/// property; the actions hop to the main actor because both stores live there.
struct MessagingRequestActions {
    let requestStore: StayRequestStore
    let messageStore: MessageStore
    let currentUserID: String

    @MainActor
    func cancel(_ request: StayRequest) async throws {
        try await requestStore.cancel(request)
        post("Request cancelled · \(request.dateRangeText)", to: request.hostUserID)
    }

    @MainActor
    func accept(_ request: StayRequest, hostNote: String?) async throws {
        try await requestStore.accept(request, hostNote: hostNote)
        var text = "✅ Stay accepted · \(request.dateRangeText)"
        if let hostNote, !hostNote.isEmpty { text += "\n\(hostNote)" }
        post(text, to: request.guestUserID)
    }

    @MainActor
    func decline(_ request: StayRequest) async throws {
        try await requestStore.decline(request)
        post("Stay request declined · \(request.dateRangeText)", to: request.guestUserID)
    }

    @MainActor
    private func post(_ text: String, to recipientUserID: String) {
        messageStore.send(text: text, senderUserID: currentUserID, recipientUserID: recipientUserID)
    }
}

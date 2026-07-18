//
//  MessagingRequestActions.swift
//  freebnb
//
//  Accept / decline / cancel / withdraw from inside a chat thread. Each action
//  mutates the request and then posts the matching system message into the
//  conversation, so the two always travel together. Split out of
//  MessagingPage.swift (A2).
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
        post(StayEvent(kind: .cancelled, dateRange: request.dateRangeText), for: request)
    }

    /// A host takes back an offer the guest hasn't answered (feature 43).
    @MainActor
    func withdraw(_ request: StayRequest) async throws {
        try await requestStore.withdrawOffer(request)
        post(StayEvent(kind: .cancelled, dateRange: request.dateRangeText), for: request)
    }

    /// Says yes from either side: the host accepting a guest's request, or the
    /// guest accepting a host's offer.
    @MainActor
    func accept(_ request: StayRequest, hostNote: String?) async throws {
        try await requestStore.accept(request, hostNote: hostNote)
        let note = (hostNote?.isEmpty ?? true) ? nil : hostNote
        post(StayEvent(kind: .accepted, dateRange: request.dateRangeText, note: note), for: request)
    }

    @MainActor
    func decline(_ request: StayRequest) async throws {
        try await requestStore.decline(request)
        post(StayEvent(kind: .declined, dateRange: request.dateRangeText), for: request)
    }

    /// A guest turns down a host's offer (feature 43).
    @MainActor
    func declineOffer(_ request: StayRequest) async throws {
        try await requestStore.declineOffer(request)
        post(StayEvent(kind: .declined, dateRange: request.dateRangeText), for: request)
    }

    /// The event always goes to the other side of the stay, whichever side the
    /// actor is on. Requests and offers point opposite ways, so neither party's
    /// ID can be hardcoded here.
    @MainActor
    private func post(_ event: StayEvent, for request: StayRequest) {
        messageStore.sendStayEvent(
            event,
            senderUserID: currentUserID,
            recipientUserID: request.otherParty(from: currentUserID)
        )
    }
}

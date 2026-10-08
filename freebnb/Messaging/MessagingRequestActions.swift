//
//  MessagingRequestActions.swift
//  freebnb
//
//  Accept / decline / cancel / withdraw from inside a chat thread: each mutates the request, then posts the matching system message.
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
        // A host calling off a confirmed stay posts the humane `hostCancelled` card with the listing; the banner has no note field. Other cancels stay plain `cancelled`.
        let hostCallingOffConfirmed = request.role(of: currentUserID) == .host && request.status == .accepted
        let event = hostCallingOffConfirmed
            ? StayEvent(kind: .hostCancelled, dateRange: request.dateRangeText, listingID: request.listingID)
            : StayEvent(kind: .cancelled, dateRange: request.dateRangeText)
        post(event, for: request)
    }

    /// A host takes back an offer the guest hasn't answered.
    @MainActor
    func withdraw(_ request: StayRequest) async throws {
        try await requestStore.withdrawOffer(request)
        post(StayEvent(kind: .cancelled, dateRange: request.dateRangeText), for: request)
    }

    /// Says yes from either side: a host accepting a request or a guest accepting an offer.
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

    /// A guest turns down a host's offer.
    @MainActor
    func declineOffer(_ request: StayRequest) async throws {
        try await requestStore.declineOffer(request)
        post(StayEvent(kind: .declined, dateRange: request.dateRangeText), for: request)
    }

    /// The event always goes to the other side of the stay; requests and offers point opposite ways, so neither ID can be hardcoded.
    @MainActor
    private func post(_ event: StayEvent, for request: StayRequest) {
        messageStore.sendStayEvent(
            event,
            senderUserID: currentUserID,
            recipientUserID: request.otherParty(from: currentUserID)
        )
    }
}

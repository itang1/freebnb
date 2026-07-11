//
//  MessagingPage.swift
//  freebnb
//
//  The one-to-one chat view. It owns the thread's state and chrome; the
//  banners, bubble list, input bar, toolbar menu, and request actions all live
//  in sibling files (A2).
//

import SwiftUI
import os

struct MessagingPage: View {
    let otherUserID: String
    let otherName: String
    /// Passed when navigating from a listing page; enables the Request to Stay
    /// toolbar action and provides listing context at the top of the thread.
    var listing: Home? = nil

    @Environment(MessageStore.self) private var messageStore
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @State private var showRequestSheet = false
    @State private var respondingTo: StayRequest?
    @State private var errorMessage: String?
    @State private var bannerBusy = false
    @State private var reportedMessage: Message?
    @State private var showReportUser = false
    @State private var showBlockConfirm = false
    @State private var searchQuery = ""

    private var currentUserID: String { authManager.userID }
    private var conversationID: String {
        MessageStore.conversationID(userIDs: [currentUserID, otherUserID])
    }
    private var participants: [String] { [currentUserID, otherUserID].sorted() }
    private var isMuted: Bool { messageStore.isMuted(conversationID) }
    private var isBlocked: Bool { userProfileStore.isBlocked(otherUserID) }

    private var activeRequest: StayRequest? {
        requestStore.outgoingRequests.first(where: { $0.hostUserID == otherUserID && $0.status.isActive })
        ?? requestStore.incomingRequests.first(where: { $0.guestUserID == otherUserID && $0.status.isActive })
    }

    private var iAmGuest: Bool { activeRequest?.guestUserID == currentUserID }

    private var actions: MessagingRequestActions {
        MessagingRequestActions(requestStore: requestStore,
                                messageStore: messageStore,
                                currentUserID: currentUserID)
    }

    @ObservationIgnored private let log = AppLog.logger("messaging")

    var body: some View {
        VStack(spacing: 0) {
            // Listing context — shown when a specific listing is associated.
            if let listing {
                ListingContextBanner(listing: listing, isMuted: isMuted)
                Divider()
            }

            if let request = activeRequest {
                StayRequestBanner(
                    request: request,
                    iAmGuest: iAmGuest,
                    isBusy: bannerBusy,
                    onCancel: { run { try await actions.cancel(request) } },
                    onDecline: { run { try await actions.decline(request) } },
                    onAccept: { respondingTo = request }
                )
                Divider()
            }

            MessageThread(
                conversationID: conversationID,
                participants: participants,
                currentUserID: currentUserID,
                otherName: otherName,
                searchQuery: searchQuery.trimmingCharacters(in: .whitespaces),
                onReport: { reportedMessage = $0 }
            )

            Divider()
            MessageInputBar(otherName: otherName, draft: $draft, isFocused: $inputFocused, onSend: sendMessage, isOffline: !networkMonitor.isOnline)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
        .toolbar {
            // Primary action: Request a Stay (only when a listing is known and no active request)
            if listing != nil, activeRequest == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Request a Stay") { showRequestSheet = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color.accent)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                ConversationActionsMenu(
                    otherName: otherName,
                    isMuted: isMuted,
                    isBlocked: isBlocked,
                    onToggleMute: {
                        isMuted ? messageStore.unmuteConversation(conversationID)
                                : messageStore.muteConversation(conversationID)
                    },
                    onReport: { showReportUser = true },
                    onToggleBlock: { showBlockConfirm = true }
                )
            }
        }
        .task {
            inputFocused = true
            messageStore.openConversation(conversationID, participants: participants)
            messageStore.markRead(conversationID: conversationID)
        }
        .onDisappear {
            messageStore.closeConversation(conversationID)
        }
        .sheet(isPresented: $showRequestSheet) {
            if let listing {
                RequestStaySheet(listing: listing)
            }
        }
        .sheet(item: $respondingTo) { request in
            AcceptSheet(request: request) { hostNote in
                await accept(request, hostNote: hostNote)
            }
        }
        .sheet(item: $reportedMessage) { msg in
            ReportSheet(
                targetType: .message,
                targetID: msg.id,
                targetName: "Message from \(otherName)"
            )
        }
        .sheet(isPresented: $showReportUser) {
            ReportSheet(
                targetType: .user,
                targetID: otherUserID,
                targetName: otherName
            )
        }
        .confirmationDialog(
            isBlocked ? "Unblock \(otherName)?" : "Block \(otherName)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            if isBlocked {
                Button("Unblock") {
                    Task {
                        try? await userProfileStore.unblockUser(otherUserID)
                    }
                }
            } else {
                Button("Block", role: .destructive) {
                    Task {
                        try? await userProfileStore.blockUser(otherUserID)
                        dismiss()
                    }
                }
            }
        } message: {
            if !isBlocked {
                Text("You won't see messages or listings from \(otherName). You can unblock them any time.")
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if messageStore.send(text: trimmed, senderUserID: currentUserID, recipientUserID: otherUserID) {
            draft = ""
        }
    }

    /// Runs a banner action, coalescing double-taps and surfacing failures.
    private func run(_ action: @escaping () async throws -> Void) {
        guard !bannerBusy else { return }
        bannerBusy = true
        Task {
            await perform(action)
            bannerBusy = false
        }
    }

    private func accept(_ request: StayRequest, hostNote: String?) async {
        let succeeded = await perform { try await actions.accept(request, hostNote: hostNote) }
        if succeeded { respondingTo = nil }
    }

    /// Returns whether the action completed; on failure it logs and raises the alert.
    @discardableResult
    private func perform(_ action: () async throws -> Void) async -> Bool {
        do {
            try await action()
            return true
        } catch {
            log.error("stay request action failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return false
        }
    }
}

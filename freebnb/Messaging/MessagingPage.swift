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
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(CheckInKitStore.self) private var checkInKitStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    /// The listing a new stay request is being composed for. Set directly when
    /// the other person has one requestable home, or by the picker when several.
    @State private var requestTarget: Home?
    @State private var showListingChoice = false
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

    /// Every active stay between the two participants, in both directions. Their
    /// request for my place and my request for theirs can be open at once, and
    /// each gets its own banner; picking one would hide the other.
    private var activeRequests: [StayRequest] {
        let outgoing = requestStore.outgoingRequests.filter {
            $0.hostUserID == otherUserID && $0.status.isActive
        }
        let incoming = requestStore.incomingRequests.filter {
            $0.guestUserID == otherUserID && $0.status.isActive
        }
        return (outgoing + incoming).sortedByDate()
    }

    /// The other person's homes I could send a stay request for right now: their
    /// listings visible to me (plus the one this thread was opened from), minus
    /// any I already have an active request on. Same per-listing rule the
    /// listing page applies; their requests for my place don't block anything.
    private var requestableListings: [Home] {
        var candidates = homeStore.visibleListings.filter { $0.hostUserID == otherUserID }
        if let listing, listing.hostUserID == otherUserID,
           !candidates.contains(where: { $0.id == listing.id }) {
            candidates.append(listing)
        }
        return candidates.filter {
            requestStore.activeRequest(for: $0.id, guestUserID: currentUserID) == nil
        }
    }

    /// The saved arrival kit for a stay at this person's place, when one is close
    /// enough to matter. Only the guest's own stays produce a kit, so this is
    /// naturally absent when the roles are the other way round.
    private var arrivalKit: CheckInKit? {
        let staysWithThem = requestStore.outgoingRequests.filter {
            $0.hostUserID == otherUserID && $0.status == .accepted
        }
        return staysWithThem
            .compactMap { checkInKitStore.kit(for: $0.id) }
            .filter { $0.hasContent && CheckInKitBanner.isRelevant($0) }
            .min { $0.checkIn < $1.checkIn }
    }

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

            // Above the request banners: on arrival day this is the only thing on
            // screen the guest is actually trying to reach.
            if let arrivalKit {
                CheckInKitBanner(kit: arrivalKit)
                Divider()
            }

            ForEach(activeRequests) { request in
                StayRequestBanner(
                    request: request,
                    viewerID: currentUserID,
                    otherName: otherName,
                    isBusy: bannerBusy,
                    onCancel: { run { try await cancelOrWithdraw(request) } },
                    onDecline: { run { try await decline(request) } },
                    onAccept: { accept(request) }
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
            // Primary action: Request a Stay, whenever the other person has a
            // home this user could request. Their open request for this user's
            // place is a different stay and doesn't take the button away.
            if !requestableListings.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Request a Stay") {
                        if requestableListings.count == 1 {
                            requestTarget = requestableListings[0]
                        } else {
                            showListingChoice = true
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    // Coral, the palette's call-to-action color: this is the
                    // thread's primary action and the only coral in the toolbar.
                    .foregroundColor(Color.callToAction)
                }
            }
            // Tapping the name opens the profile — the thread's bridge to the
            // person hub, where relationship actions (unfriend) and the full
            // safety controls live.
            ToolbarItem(placement: .principal) {
                NavigationLink {
                    UserProfilePage(userID: otherUserID, fallbackName: otherName)
                } label: {
                    HStack(spacing: 3) {
                        Text(otherName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityLabel("\(otherName), view profile")
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
        .sheet(item: $requestTarget) { home in
            RequestStaySheet(listing: home)
        }
        .confirmationDialog(
            "Which of \(otherName)'s places?",
            isPresented: $showListingChoice,
            titleVisibility: .visible
        ) {
            ForEach(requestableListings) { home in
                Button(home.displayTitle) { requestTarget = home }
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

    /// The banner's cancel slot: a host taking back their own offer withdraws
    /// it; everything else (a guest's request, an accepted stay) is a cancel.
    private func cancelOrWithdraw(_ request: StayRequest) async throws {
        if request.status == .offered {
            try await actions.withdraw(request)
        } else {
            try await actions.cancel(request)
        }
    }

    /// The banner's decline slot: a guest turning down an offer and a host
    /// turning down a request are different writes with the same button.
    private func decline(_ request: StayRequest) async throws {
        if request.status == .offered {
            try await actions.declineOffer(request)
        } else {
            try await actions.decline(request)
        }
    }

    /// The banner's accept slot. A host accepting a request gets the note sheet;
    /// a guest saying yes to an offer accepts directly, like the Stays tab.
    private func accept(_ request: StayRequest) {
        if request.status == .offered {
            run { try await actions.accept(request, hostNote: nil) }
        } else {
            respondingTo = request
        }
    }

    /// Returns nil on success, or the failure message for `AcceptSheet` to show.
    /// Routed to the sheet rather than through `perform`, whose alert would be
    /// swallowed behind the presented sheet. The sheet self-dismisses on success.
    private func accept(_ request: StayRequest, hostNote: String?) async -> String? {
        do {
            try await actions.accept(request, hostNote: hostNote)
            return nil
        } catch {
            log.error("stay request accept failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
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

#Preview {
    NavigationStack {
        MessagingPage(otherUserID: PreviewData.friendID, otherName: "Maya", listing: PreviewData.home)
    }
    .previewEnvironment()
}

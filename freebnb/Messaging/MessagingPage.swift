//
//  MessagingPage.swift
//  freebnb
//
//  The one-to-one chat view. The conversation list, its row, the message
//  bubble, and the navigation route now live in sibling files (A2).
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

    private var trimmedSearchQuery: String { searchQuery.trimmingCharacters(in: .whitespaces) }
    private var isLoadingThread: Bool { messageStore.isLoadingThread(conversationID) }

    private var allMessages: [Message] { messageStore.messages(for: conversationID) }
    private var messages: [Message] {
        let q = trimmedSearchQuery
        guard !q.isEmpty else { return allMessages }
        return allMessages.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
    private var hasMoreMessages: Bool { messageStore.hasMoreMessages(conversationID) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var activeRequest: StayRequest? {
        requestStore.outgoingRequests.first(where: { $0.hostUserID == otherUserID && $0.status.isActive })
        ?? requestStore.incomingRequests.first(where: { $0.guestUserID == otherUserID && $0.status.isActive })
    }

    private var iAmGuest: Bool { activeRequest?.guestUserID == currentUserID }

    @ObservationIgnored private let log = AppLog.logger("messaging")

    var body: some View {
        VStack(spacing: 0) {
            // Listing context — shown when a specific listing is associated.
            if let listing {
                listingContextBanner(listing)
                Divider()
            }

            if let req = activeRequest {
                requestBanner(req)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if hasMoreMessages {
                            Button {
                                messageStore.loadMoreMessages(conversationID, participants: participants)
                            } label: {
                                Label("Load older messages", systemImage: "arrow.up.circle")
                                    .font(.subheadline)
                                    .foregroundColor(Color.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }

                        if messages.isEmpty {
                            if !trimmedSearchQuery.isEmpty {
                                Text("No messages match \"\(trimmedSearchQuery)\"")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 48)
                                    .padding(.horizontal, 24)
                            } else if isLoadingThread {
                                // Only stands in for the unknown-yet state: a thread
                                // already backed by the global snapshot skips this.
                                SkeletonMessageThread()
                                    .accessibilityElement()
                                    .accessibilityLabel("Loading messages")
                            } else {
                                Text("Send \(otherName) a message to get started.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 48)
                                    .padding(.horizontal, 24)
                            }
                        }
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                currentUserID: currentUserID,
                                state: messageStore.state(of: message.id),
                                onRetry: { messageStore.retry(message.id) },
                                onDiscard: { messageStore.discardFailed(message.id) },
                                onReport: { reportedMessage = message }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: allMessages.last?.id) { _, lastID in
                    if let lastID, searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                    messageStore.markRead(conversationID: conversationID)
                }
            }

            Divider()
            inputBar
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
            // Secondary: conversation actions menu
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if isMuted {
                        Button {
                            messageStore.unmuteConversation(conversationID)
                        } label: {
                            Label("Unmute Conversation", systemImage: "bell")
                        }
                    } else {
                        Button {
                            messageStore.muteConversation(conversationID)
                        } label: {
                            Label("Mute Conversation", systemImage: "bell.slash")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        showReportUser = true
                    } label: {
                        Label("Report \(otherName)", systemImage: "flag")
                    }

                    Button(role: .destructive) {
                        showBlockConfirm = true
                    } label: {
                        Label(isBlocked ? "Unblock \(otherName)" : "Block \(otherName)",
                              systemImage: isBlocked ? "person.fill.checkmark" : "person.fill.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
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
        .sheet(item: $respondingTo) { req in
            AcceptSheet(request: req) { hostNote in
                await acceptRequest(req, hostNote: hostNote)
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

    // MARK: - Listing context banner

    private func listingContextBanner(_ home: Home) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "house.fill")
                .font(.subheadline)
                .foregroundColor(.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Re: \(home.hostName)'s place")
                    .font(.subheadline).fontWeight(.semibold)
                Text("\(home.address.city), \(home.address.state)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Muted")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accent.opacity(0.07))
    }

    // MARK: - Request banner

    @ViewBuilder
    private func requestBanner(_ request: StayRequest) -> some View {
        let bannerColor: Color = request.status == .accepted ? .green : .orange
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusBadge(status: request.status)
                    Text(dateRangeText(request))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let note = request.guestNote, !note.isEmpty {
                    Text("\"\(note)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if iAmGuest, request.status.isActive {
                Button("Cancel") {
                    guard !bannerBusy else { return }
                    bannerBusy = true
                    Task {
                        await cancelRequest(request)
                        bannerBusy = false
                    }
                }
                .font(.caption)
                .foregroundColor(.red)
                .disabled(bannerBusy)
            } else if !iAmGuest, request.status == .pending {
                HStack(spacing: 8) {
                    Button("Decline") {
                        guard !bannerBusy else { return }
                        bannerBusy = true
                        Task {
                            await declineRequest(request)
                            bannerBusy = false
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .disabled(bannerBusy)
                    Button("Accept") { respondingTo = request }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accent)
                        .clipShape(Capsule())
                        .disabled(bannerBusy)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bannerColor.opacity(0.08))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(otherName)...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(20)
                .focused($inputFocused)
                .lineLimit(1...5)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(trimmedDraft.isEmpty ? .secondary.opacity(0.4) : .accent)
            }
            .disabled(trimmedDraft.isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.primaryBackground)
    }

    // MARK: - Sending

    private func sendMessage() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        if messageStore.send(text: trimmed, senderUserID: currentUserID, recipientUserID: otherUserID) {
            draft = ""
        }
    }

    // MARK: - Request actions

    private func dateRangeText(_ request: StayRequest) -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))"
    }

    private func cancelRequest(_ request: StayRequest) async {
        do {
            try await requestStore.cancel(request)
            messageStore.send(
                text: "Request cancelled · \(dateRangeText(request))",
                senderUserID: currentUserID,
                recipientUserID: request.hostUserID
            )
        } catch {
            log.error("cancel request failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func acceptRequest(_ request: StayRequest, hostNote: String?) async {
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            var text = "✅ Stay accepted · \(dateRangeText(request))"
            if let note = hostNote, !note.isEmpty { text += "\n\(note)" }
            messageStore.send(
                text: text,
                senderUserID: currentUserID,
                recipientUserID: request.guestUserID
            )
            respondingTo = nil
        } catch {
            log.error("accept request failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func declineRequest(_ request: StayRequest) async {
        do {
            try await requestStore.decline(request)
            messageStore.send(
                text: "Stay request declined · \(dateRangeText(request))",
                senderUserID: currentUserID,
                recipientUserID: request.guestUserID
            )
        } catch {
            log.error("decline request failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}

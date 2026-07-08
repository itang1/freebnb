//
//  MessagingPage.swift
//  freebnb
//

import SwiftUI
import os

// Used by MessagesTab's NavigationStack path so deep links can push
// programmatically without touching the parent's navigation state.
struct ConversationRoute: Hashable {
    let otherUserID: String
    let otherName: String
    let listing: Home?

    static func == (lhs: ConversationRoute, rhs: ConversationRoute) -> Bool {
        lhs.otherUserID == rhs.otherUserID
    }

    func hash(into hasher: inout Hasher) { hasher.combine(otherUserID) }
}

// MARK: - MessagingPage

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
                                    .foregroundColor(Color.appTeal)
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
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
        .toolbar {
            // Primary action: Request a Stay (only when a listing is known and no active request)
            if listing != nil, activeRequest == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Request a Stay") { showRequestSheet = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color.appTeal)
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
                .foregroundColor(.appTeal)
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
        .background(Color.appTeal.opacity(0.07))
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
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.appTeal)
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
                    .foregroundColor(trimmedDraft.isEmpty ? .secondary.opacity(0.4) : .appTeal)
            }
            .disabled(trimmedDraft.isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.creamWhite)
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

// MARK: - Bubble

private struct MessageBubble: View {
    let message: Message
    let currentUserID: String
    let state: MessageState
    let onRetry: () -> Void
    let onDiscard: () -> Void
    var onReport: () -> Void = {}

    private var isFromMe: Bool { message.senderUserID == currentUserID }
    private var isFailed: Bool { state == .failed }

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 3) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundColor(isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isFailed ? Color.red.opacity(0.5) : .clear, lineWidth: 1)
                    )
                    .contextMenu {
                        if isFailed {
                            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            Button("Delete", systemImage: "trash", role: .destructive, action: onDiscard)
                        }
                        if !isFromMe {
                            Button("Report", systemImage: "flag", role: .destructive, action: onReport)
                        }
                    }

                footer
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
    }

    private var bubbleBackground: Color {
        if isFailed { return Color.red.opacity(0.15) }
        return isFromMe ? Color.appTeal : Color.secondary.opacity(0.15)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            if isFromMe {
                switch state {
                case .pending:
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Sending")
                case .failed:
                    Button(action: onRetry) {
                        Label("Not delivered, tap to retry", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                case .sent:
                    EmptyView()
                }
            }
            if state != .failed {
                Text(message.timestamp ?? Date(), style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Conversation list tab

struct MessagesTab: View {
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(StayRequestStore.self) private var requestStore

    let listings: [Home]
    /// Set by ContentView when a push notification tap should open a conversation.
    var deepLinkUserID: Binding<String?>

    @State private var path: [ConversationRoute] = []
    @State private var searchQuery = ""

    // MARK: - Helpers

    private func displayName(for userID: String) -> String {
        if let name = userProfileStore.displayName(for: userID), !name.isEmpty { return name }
        if let host = listings.first(where: { $0.hostUserID == userID })?.hostName { return host }
        return "FreeBNB User"
    }

    /// Finds the listing associated with this conversation by looking at stay
    /// requests. Used to pass listing context into the thread.
    private func listing(for otherUserID: String) -> Home? {
        let request = requestStore.outgoingRequests.first { $0.hostUserID == otherUserID }
            ?? requestStore.incomingRequests.first { $0.guestUserID == otherUserID }
        guard let listingID = request?.listingID else { return nil }
        return listings.first { $0.id == listingID }
    }

    private var visibleSummaries: [ConversationSummary] {
        let blocked = userProfileStore.currentProfile?.blockedIDs ?? []
        let all = messageStore.conversationSummaries.filter { !blocked.contains($0.otherUserID) }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { summary in
            displayName(for: summary.otherUserID).lowercased().contains(q) ||
            summary.lastMessage.text.lowercased().contains(q)
        }
    }

    /// Skeletons stand in only for the not-yet-known empty state. Once any
    /// conversation has arrived the real list is the better answer, and a search
    /// that matches nothing is a result rather than a pending load.
    private var showingSkeletons: Bool {
        messageStore.isLoadingConversations && visibleSummaries.isEmpty && searchQuery.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if showingSkeletons {
                    List(0..<6, id: \.self) { _ in
                        SkeletonConversationRow()
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.creamWhite.ignoresSafeArea())
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Loading conversations")
                    .transition(.opacity)
                } else if visibleSummaries.isEmpty && searchQuery.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "message")
                            .foregroundStyle(Color.appTeal)
                    } description: {
                        Text("Open a listing and message the host to get started.")
                    }
                    .background(Color.creamWhite.ignoresSafeArea())
                } else if visibleSummaries.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                        .background(Color.creamWhite.ignoresSafeArea())
                } else {
                    List {
                        ForEach(visibleSummaries) { summary in
                            let name = displayName(for: summary.otherUserID)
                            let route = ConversationRoute(
                                otherUserID: summary.otherUserID,
                                otherName: name,
                                listing: listing(for: summary.otherUserID)
                            )
                            NavigationLink(value: route) {
                                ConversationRow(
                                    otherName: name,
                                    lastMessage: summary.lastMessage,
                                    currentUserID: authManager.userID,
                                    isMuted: messageStore.isMuted(summary.id),
                                    isUnread: messageStore.isUnread(summary.id, currentUserID: authManager.userID)
                                )
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.creamWhite.ignoresSafeArea())
                    .transition(.opacity)
                    .animatesListChanges(on: visibleSummaries.map(\.id))
                }
            }
            .animation(AppAnimation.contentSwap, value: showingSkeletons)
            .navigationTitle("Messages")
            .searchable(text: $searchQuery, prompt: "Search conversations")
            .navigationDestination(for: ConversationRoute.self) { route in
                MessagingPage(
                    otherUserID: route.otherUserID,
                    otherName: route.otherName,
                    listing: route.listing
                )
            }
        }
        .onChange(of: deepLinkUserID.wrappedValue) { _, userID in
            guard let userID else { return }
            let name = displayName(for: userID)
            path.append(ConversationRoute(
                otherUserID: userID,
                otherName: name,
                listing: listing(for: userID)
            ))
            deepLinkUserID.wrappedValue = nil
        }
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let otherName: String
    let lastMessage: Message
    let currentUserID: String
    var isMuted: Bool = false
    var isUnread: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.appTeal.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(otherName.prefix(1)))
                    .font(.headline)
                    .foregroundColor(.appTeal)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(otherName)
                        .font(isUnread ? .headline.weight(.semibold) : .headline)
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Muted")
                    }
                }
                HStack(spacing: 2) {
                    if lastMessage.senderUserID == currentUserID {
                        Text("You: ")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Text(lastMessage.text)
                        .font(.subheadline)
                        .foregroundColor(isUnread ? .primary : .secondary)
                        .fontWeight(isUnread ? .medium : .regular)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(lastMessage.timestamp ?? Date(), style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isUnread {
                    Circle()
                        .fill(Color.appTeal)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        parts.append(otherName)
        if isMuted { parts.append("muted") }
        let preview = lastMessage.senderUserID == currentUserID
            ? "You: \(lastMessage.text)"
            : lastMessage.text
        parts.append(preview)
        if isUnread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

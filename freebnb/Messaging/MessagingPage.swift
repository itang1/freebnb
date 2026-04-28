//
//  MessagingPage.swift
//  freebnb
//

import SwiftUI
import os

struct MessagingPage: View {
    let otherUserID: String
    let otherName: String
    /// Passed when navigating from a listing page; enables the Request to Stay
    /// toolbar action and provides listing context for the request sheet.
    var listing: Home? = nil

    @Environment(MessageStore.self) private var messageStore
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(AuthManager.self) private var authManager
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @State private var showRequestSheet = false
    @State private var respondingTo: StayRequest?
    @State private var errorMessage: String?
    @State private var bannerBusy = false

    private var currentUserID: String { authManager.userID }
    private var conversationID: String {
        MessageStore.conversationID(userIDs: [currentUserID, otherUserID])
    }
    private var participants: [String] { [currentUserID, otherUserID].sorted() }
    private var messages: [Message] { messageStore.messages(for: conversationID) }
    private var hasMoreMessages: Bool { messageStore.hasMoreMessages(conversationID) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The most recent active request between these two users, from either direction.
    private var activeRequest: StayRequest? {
        requestStore.outgoingRequests.first(where: { $0.hostUserID == otherUserID && $0.status.isActive })
        ?? requestStore.incomingRequests.first(where: { $0.guestUserID == otherUserID && $0.status.isActive })
    }

    private var iAmGuest: Bool { activeRequest?.guestUserID == currentUserID }

    @ObservationIgnored private let log = AppLog.logger("messaging")

    var body: some View {
        VStack(spacing: 0) {
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
                            Text("Send \(otherName) a message to get started.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 48)
                                .padding(.horizontal, 24)
                        }
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                currentUserID: currentUserID,
                                state: messageStore.state(of: message.id),
                                onRetry: { messageStore.retry(message.id) },
                                onDiscard: { messageStore.discardFailed(message.id) }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.last?.id) { _, lastID in
                    if let lastID {
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
        .toolbar {
            // Show the request button only when a listing is known and there
            // is no active request already in flight.
            if listing != nil, activeRequest == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Request a Stay") { showRequestSheet = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color.appTeal)
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
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
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

    // MARK: - Request actions (mirror StaysTab; messages keep both sides in sync)

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
    let listings: [Home]

    private func displayName(for userID: String) -> String {
        if let name = userProfileStore.displayName(for: userID), !name.isEmpty { return name }
        if let host = listings.first(where: { $0.hostUserID == userID })?.hostName { return host }
        return "FreeBNB User"
    }

    var body: some View {
        let summaries = messageStore.conversationSummaries
        Group {
            if summaries.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "message")
                        .foregroundStyle(Color.appTeal)
                } description: {
                    Text("Open a listing and message the host to get started.")
                }
                .background(Color.creamWhite.ignoresSafeArea())
            } else {
                List {
                    ForEach(summaries) { summary in
                        let name = displayName(for: summary.otherUserID)
                        NavigationLink {
                            MessagingPage(otherUserID: summary.otherUserID, otherName: name)
                        } label: {
                            ConversationRow(
                                otherName: name,
                                lastMessage: summary.lastMessage,
                                currentUserID: authManager.userID
                            )
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.creamWhite.ignoresSafeArea())
            }
        }
        .navigationTitle("Messages")
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let otherName: String
    let lastMessage: Message
    let currentUserID: String

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
                Text(otherName)
                    .font(.headline)
                HStack(spacing: 2) {
                    if lastMessage.senderUserID == currentUserID {
                        Text("You: ")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Text(lastMessage.text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(lastMessage.timestamp ?? Date(), style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

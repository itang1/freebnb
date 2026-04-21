//
//  MessagingPage.swift
//  freebnb
//

import SwiftUI

struct MessagingPage: View {
    let otherUserID: String
    let otherName: String

    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var currentUserID: String { authManager.userID }
    private var conversationID: String {
        MessageStore.conversationID(userIDs: [currentUserID, otherUserID])
    }
    private var messages: [Message] { messageStore.messages(for: conversationID) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
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
                }
            }

            Divider()

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
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .task { inputFocused = true }
    }

    private func sendMessage() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        if messageStore.send(text: trimmed, senderUserID: currentUserID, recipientUserID: otherUserID) {
            draft = ""
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

    // Prefer the profile store (works for any user), fall back to the host name
    // from listings if we happen to know them that way, else a neutral placeholder.
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

//
//  MessagingPage.swift
//  freebnb
//

import SwiftUI

struct MessagingPage: View {
    let otherUserID: String
    let otherName: String

    @EnvironmentObject var messageStore: MessageStore
    @EnvironmentObject var authManager: AuthManager
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var currentUserID: String { authManager.userID }
    private var conversationID: String {
        MessageStore.conversationID(userIDs: [currentUserID, otherUserID])
    }
    private var messages: [Message] { messageStore.messages(for: conversationID) }

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
                                isPending: messageStore.isPending(message.id)
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
                        .foregroundColor(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? .secondary.opacity(0.4)
                                : Color("AppTeal")
                        )
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.creamWhite)
        }
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sent = messageStore.send(text: trimmed, senderUserID: currentUserID, recipientUserID: otherUserID)
        if sent { draft = "" }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: Message
    let currentUserID: String
    let isPending: Bool

    private var isFromMe: Bool { message.senderUserID == currentUserID }

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 3) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isFromMe ? Color("AppTeal") : Color.secondary.opacity(0.15))
                    .foregroundColor(isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 4) {
                    if isFromMe && isPending {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(message.timestamp ?? Date(), style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Conversation list tab

struct MessagesTab: View {
    @EnvironmentObject var messageStore: MessageStore
    @EnvironmentObject var authManager: AuthManager
    let listings: [Home]

    // Resolve a display name for a user ID: check if they're a known host, else "Guest".
    private func displayName(for userID: String) -> String {
        listings.first { $0.hostUserID == userID }?.hostName ?? "Guest"
    }

    var body: some View {
        let summaries = messageStore.conversationSummaries
        Group {
            if summaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "message")
                        .font(.system(size: 48))
                        .foregroundColor(Color("AppTeal").opacity(0.35))
                    Text("No conversations yet")
                        .font(.headline)
                    Text("Open a listing and message the host to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .fill(Color("AppTeal").opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(otherName.prefix(1)))
                    .font(.headline)
                    .foregroundColor(Color("AppTeal"))
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

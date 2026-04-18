//
//  MessagingPage.swift
//  freebnb
//

import SwiftUI

// MARK: - Model

struct Message: Identifiable {
    let id = UUID()
    let senderUserID: String
    let text: String
    let timestamp: Date
}

// MARK: - Store

class MessageStore: ObservableObject {
    @Published private var conversations: [UUID: [Message]] = [:]

    func messages(for homeID: UUID) -> [Message] {
        conversations[homeID] ?? []
    }

    func hasMessages(for homeID: UUID) -> Bool {
        !(conversations[homeID]?.isEmpty ?? true)
    }

    func send(text: String, to homeID: UUID, senderUserID: String) {
        let msg = Message(senderUserID: senderUserID, text: text, timestamp: Date())
        conversations[homeID, default: []].append(msg)
    }
}

// MARK: - Chat view

struct MessagingPage: View {
    let home: Home
    @EnvironmentObject var messageStore: MessageStore
    @EnvironmentObject var authManager: AuthManager
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [Message] { messageStore.messages(for: home.id) }
    private var currentUserID: String { authManager.userID }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if messages.isEmpty {
                            Text("Send \(home.hostName) a message to get started.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 48)
                                .padding(.horizontal, 24)
                        }
                        ForEach(messages) { message in
                            MessageBubble(message: message, currentUserID: currentUserID)
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
                TextField("Message \(home.hostName)...", text: $draft, axis: .vertical)
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
        .navigationTitle(home.hostName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messageStore.send(text: trimmed, to: home.id, senderUserID: currentUserID)
        draft = ""
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: Message
    let currentUserID: String

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

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

    private var activeConversations: [Home] {
        listings.filter { messageStore.hasMessages(for: $0.id) }
    }

    var body: some View {
        Group {
            if activeConversations.isEmpty {
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
                    ForEach(activeConversations) { home in
                        NavigationLink {
                            MessagingPage(home: home)
                        } label: {
                            ConversationRow(
                                home: home,
                                lastMessage: messageStore.messages(for: home.id).last!,
                                currentUserID: authManager.userID
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Messages")
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let home: Home
    let lastMessage: Message
    let currentUserID: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color("AppTeal").opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(home.hostName.prefix(1)))
                    .font(.headline)
                    .foregroundColor(Color("AppTeal"))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(home.hostName)
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

            Text(lastMessage.timestamp, style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

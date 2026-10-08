//
//  MessageThread.swift
//  freebnb
//
//  The scrolling bubble list in a chat, with its empty, loading and no-search-results states.
//

import SwiftUI

struct MessageThread: View {
    let conversationID: String
    let participants: [String]
    let currentUserID: String
    let otherName: String
    /// Already trimmed by the caller; empty means "no filter".
    let searchQuery: String
    let onReport: (Message) -> Void

    @Environment(MessageStore.self) private var messageStore

    /// Applies the search filter, taking the thread rather than reading it so a body pass sorts once.
    private func filtered(_ all: [Message]) -> [Message] {
        guard !searchQuery.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        // Read once per body pass; `messages(for:)` re-sorts the thread on every call, which cost three sorts on the longest collection.
        let allMessages = messageStore.messages(for: conversationID)
        let messages = filtered(allMessages)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messageStore.hasMoreMessages(conversationID) {
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

                    if messages.isEmpty { placeholder }

                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            currentUserID: currentUserID,
                            otherName: otherName,
                            state: messageStore.state(of: message.id),
                            onRetry: { messageStore.retry(message.id) },
                            onDiscard: { messageStore.discardFailed(message.id) },
                            onReport: { onReport(message) }
                        )
                        .id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: allMessages.last?.id) { _, lastID in
                if let lastID, searchQuery.isEmpty {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
                messageStore.markRead(conversationID: conversationID)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !searchQuery.isEmpty {
            emptyText("No messages match \"\(searchQuery)\"")
        } else if messageStore.isLoadingThread(conversationID) {
            // Stands in only for the unknown-yet state; a thread backed by the global snapshot skips it.
            SkeletonMessageThread()
                .accessibilityElement()
                .accessibilityLabel("Loading messages")
        } else {
            // The medallion decorates only a new thread; a search miss stays plain text so it reads as a result.
            VStack(spacing: 16) {
                EmptyStateMedallion(systemImage: "bubble.left.and.bubble.right")
                Text("Send \(otherName) a message to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 48)
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.top, 48)
            .padding(.horizontal, 24)
    }
}

#Preview {
    // Fed by a live listener, so an unopened conversation renders the empty state, the branch worth eyeballing.
    MessageThread(
        conversationID: "preview-conversation",
        participants: ["preview-me", "preview-them"],
        currentUserID: "preview-me",
        otherName: "Shai",
        searchQuery: "",
        onReport: { _ in }
    )
    .previewEnvironment()
}

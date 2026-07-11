//
//  MessageInputBar.swift
//  freebnb
//
//  The compose field pinned to the bottom of a chat thread. Split out of
//  MessagingPage.swift (A2).
//

import SwiftUI

struct MessageInputBar: View {
    let otherName: String
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void
    /// When offline, sending still works: Firestore queues the write and replays
    /// it on reconnect. The bar stays enabled and shows a reassuring caption so
    /// the user knows the message isn't lost (feature 41).
    var isOffline: Bool = false

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if isOffline {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Offline — this will send when you reconnect.")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(otherName)...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(20)
                    .focused($isFocused)
                    .lineLimit(1...5)

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(isEmpty ? .secondary.opacity(0.4) : .accent)
                }
                .disabled(isEmpty)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.primaryBackground)
    }
}

/// `@FocusState` can't be declared in a `#Preview` body, so it needs a host view.
private struct MessageInputBarPreview: View {
    @State private var draft = "See you Friday!"
    @FocusState private var focused: Bool

    var body: some View {
        MessageInputBar(otherName: "Shai", draft: $draft, isFocused: $focused, onSend: {})
    }
}

#Preview {
    MessageInputBarPreview()
}

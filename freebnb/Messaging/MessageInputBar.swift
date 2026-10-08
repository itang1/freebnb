//
//  MessageInputBar.swift
//  freebnb
//
//  The compose field pinned to the bottom of a chat thread.
//

import SwiftUI

struct MessageInputBar: View {
    let otherName: String
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void
    /// Offline, sending still works (Firestore queues and replays); the bar stays enabled with a caption so
    /// the user knows it isn't lost.
    var isOffline: Bool = false

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if isOffline {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Offline. This will send when you reconnect.")
                }
                .font(.caption2)
                .foregroundColor(.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(otherName)...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondaryText.opacity(0.1))
                    .cornerRadius(20)
                    .focused($isFocused)
                    .lineLimit(1...5)

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(isEmpty ? .secondaryText.opacity(0.4) : .accent)
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

/// Takes the composer's place once the friendship that opened the thread is gone. Messaging is friend-gated in the
/// rules, so a live composer would accept and echo a message then fail the write unretryably; history stays
/// readable.
/// Blocking isn't mentioned (it's in the menu), since raising it here would read as a suggestion to escalate.
struct MessageThreadClosedFooter: View {
    let otherName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.slash")
            Text("You and \(otherName) aren't friends, so this thread is read-only. Adding each other again reopens it.")
        }
        .font(.footnote)
        .foregroundColor(.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.primaryBackground)
        .accessibilityElement(children: .combine)
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

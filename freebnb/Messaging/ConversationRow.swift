//
//  ConversationRow.swift
//  freebnb
//
//  A row in the conversations list (MessagesTab). Split out of the former
//  732-line MessagingPage.swift (A2).
//

import SwiftUI

struct ConversationRow: View {
    let otherName: String
    let lastMessage: Message
    let currentUserID: String
    var isMuted: Bool = false
    var isUnread: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: otherName, size: 44)

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
                        .fill(Color.accent)
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

#Preview {
    List {
        ConversationRow(
            otherName: "Maya",
            lastMessage: PreviewData.message,
            currentUserID: PreviewData.viewerID,
            isUnread: true
        )
        ConversationRow(
            otherName: "Sam",
            lastMessage: PreviewData.message,
            currentUserID: PreviewData.friendID,
            isMuted: true
        )
    }
    .listStyle(.plain)
}

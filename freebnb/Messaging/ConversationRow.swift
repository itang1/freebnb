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
    /// Seeds the avatar. The ID rather than the name, so the person keeps the
    /// same avatar here as everywhere else even if they rename themselves.
    let otherUserID: String
    let lastMessage: Message
    let currentUserID: String
    var isMuted: Bool = false
    var isUnread: Bool = false
    /// The live stay between these two, if any. Nil for a plain friend chat,
    /// which keeps its row exactly as it was.
    var stayContext: ConversationStayContext?

    var body: some View {
        HStack(spacing: 12) {
            GeneratedAvatar(seed: otherUserID, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(otherName)
                        .font(isUnread ? .headline.weight(.semibold) : .headline)
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                            .accessibilityLabel("Muted")
                    }
                }
                HStack(spacing: 2) {
                    if lastMessage.senderUserID == currentUserID {
                        Text("You: ")
                            .font(.subheadline)
                            .foregroundColor(.secondaryText)
                    }
                    Text(lastMessage.text)
                        .font(.subheadline)
                        .foregroundColor(isUnread ? .primary : .secondary)
                        .fontWeight(isUnread ? .medium : .regular)
                        .lineLimit(1)
                }

                if let stayContext {
                    HStack(spacing: 4) {
                        Image(systemName: stayContext.systemImage)
                            .font(.caption2)
                        Text(stayContext.label)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(stayContext.isActionable ? Color.accent : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (stayContext.isActionable ? Color.accent : Color.secondary).opacity(0.12),
                        in: Capsule()
                    )
                    .padding(.top, 2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(lastMessage.timestamp ?? Date(), style: .time)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                if isUnread {
                    // Coral rather than teal: teal is everywhere as chrome, so
                    // an attention marker needs the palette's warm color to
                    // register as "needs you".
                    Circle()
                        .fill(Color.callToAction)
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
        if let stayContext { parts.append(stayContext.label) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    List {
        ConversationRow(
            otherName: "Maya",
            otherUserID: PreviewData.friendID,
            lastMessage: PreviewData.message,
            currentUserID: PreviewData.viewerID,
            isUnread: true
        )
        ConversationRow(
            otherName: "Sam",
            otherUserID: PreviewData.viewerID,
            lastMessage: PreviewData.message,
            currentUserID: PreviewData.friendID,
            isMuted: true
        )
    }
    .listStyle(.plain)
}

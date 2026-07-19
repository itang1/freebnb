//
//  MessageBubble.swift
//  freebnb
//
//  A single chat bubble rendered in MessagingPage. Split out of the former
//  732-line MessagingPage.swift (A2).
//

import SwiftUI

struct MessageBubble: View {
    let message: Message
    let currentUserID: String
    /// The other participant's display name, so a centered stay event card can
    /// name who acted; a card has no left/right side to say it.
    let otherName: String
    let state: MessageState
    let onRetry: () -> Void
    let onDiscard: () -> Void
    var onReport: () -> Void = {}

    private var isFromMe: Bool { message.senderUserID == currentUserID }
    private var isFailed: Bool { state == .failed }

    var body: some View {
        if let event = message.event {
            // Structured stay events render as a centered system card, not a
            // left/right chat bubble (item 29).
            StayEventCard(event: event, timestamp: message.timestamp,
                          isFromMe: isFromMe, otherName: otherName, state: state)
        } else {
            textBubble
        }
    }

    private var textBubble: some View {
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
        return isFromMe ? Color.accent : Color.secondary.opacity(0.15)
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
                        Label("Not delivered. Tap to retry", systemImage: "exclamationmark.circle.fill")
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

#Preview {
    VStack(spacing: 12) {
        MessageBubble(
            message: PreviewData.message,
            currentUserID: PreviewData.viewerID,
            otherName: "Maya",
            state: .sent,
            onRetry: {},
            onDiscard: {}
        )
        MessageBubble(
            message: PreviewData.message,
            currentUserID: PreviewData.friendID,
            otherName: "Maya",
            state: .failed,
            onRetry: {},
            onDiscard: {}
        )
    }
    .padding()
}

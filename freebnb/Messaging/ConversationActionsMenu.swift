//
//  ConversationActionsMenu.swift
//  freebnb
//
//  The mute / report / block overflow menu in a chat thread's toolbar. Split
//  out of MessagingPage.swift (A2).
//

import SwiftUI

struct ConversationActionsMenu: View {
    let otherName: String
    let isMuted: Bool
    let isBlocked: Bool
    let onToggleMute: () -> Void
    let onReport: () -> Void
    let onToggleBlock: () -> Void

    var body: some View {
        Menu {
            Button(action: onToggleMute) {
                Label(isMuted ? "Unmute Conversation" : "Mute Conversation",
                      systemImage: isMuted ? "bell" : "bell.slash")
            }

            Divider()

            Button(role: .destructive, action: onReport) {
                Label("Report \(otherName)", systemImage: "flag")
            }

            Button(role: .destructive, action: onToggleBlock) {
                Label(isBlocked ? "Unblock \(otherName)" : "Block \(otherName)",
                      systemImage: isBlocked ? "person.fill.checkmark" : "person.fill.xmark")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

#Preview {
    ConversationActionsMenu(otherName: "Shai", isMuted: false, isBlocked: false,
                            onToggleMute: {}, onReport: {}, onToggleBlock: {})
}

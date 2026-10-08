//
//  StayEventCard.swift
//  freebnb
//
//  The centered system card a thread renders for a stay-lifecycle event, replacing the emoji-prefixed bubble; the message keeps its `text`.
//

import SwiftUI

struct StayEventCard: View {
    let event: StayEvent
    let timestamp: Date?
    /// Whether the signed-in user did this, and who the other is; the card has no side, so its title says who acted.
    let isFromMe: Bool
    let otherName: String
    /// Pending while the send is in flight, failed if it never committed.
    var state: MessageState = .sent
    /// Set only for a `hostCancelled` event shown to the guest: opens the listing for its other dates, a quiet button they can ignore.
    var onSeeOtherDates: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }

            Text(event.dateRange)
                .font(.caption)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)

            if let note = event.note, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let onSeeOtherDates {
                Button("See other dates", action: onSeeOtherDates)
                    .font(.caption.weight(.medium))
                    .foregroundColor(Color.accent)
                    .padding(.top, 2)
            }

            footer
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(event.dateRange)")
    }

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .pending:
            Label("Sending", systemImage: "clock")
                .font(.caption2)
                .foregroundColor(.secondaryText)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Sending")
        case .failed:
            Label("Not delivered", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.danger)
        case .sent:
            if let timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }
        }
    }

    private var title: String {
        let actor = isFromMe ? "You" : otherName
        switch event.kind {
        case .requested: return "\(actor) requested to stay"
        case .offered:   return isFromMe ? "You offered your place" : "\(otherName) offered their place"
        case .accepted:  return "\(actor) accepted the stay"
        case .declined:  return "\(actor) declined the stay"
        case .cancelled: return "\(actor) cancelled the stay"
        // The guest reads that the host had to call it off; the host's own copy stays plain.
        case .hostCancelled: return isFromMe ? "You cancelled the stay" : "\(otherName) had to cancel the stay"
        case .modified:  return "\(actor) changed the dates"
        }
    }

    private var iconName: String {
        switch event.kind {
        case .requested: return "calendar"
        case .offered:   return "gift"
        case .accepted:  return "checkmark.circle.fill"
        case .declined:  return "xmark.circle"
        case .cancelled, .hostCancelled: return "slash.circle"
        case .modified:  return "calendar.badge.clock"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .requested, .modified: return .accent
        // Green like an acceptance: an offer is good news landing in the thread, not a question.
        case .offered:   return .green
        case .accepted:  return .green
        case .declined, .cancelled, .hostCancelled: return .secondary
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StayEventCard(event: StayEvent(kind: .requested, dateRange: "Mar 3 – Mar 6 · 3 nights"),
                      timestamp: Date(), isFromMe: true, otherName: "Maya")
        StayEventCard(event: StayEvent(kind: .accepted, dateRange: "Mar 3 – Mar 6 · 3 nights",
                                       note: "Door code is 1988. See you then!"),
                      timestamp: Date(), isFromMe: false, otherName: "Maya")
        StayEventCard(event: StayEvent(kind: .declined, dateRange: "Mar 3 – Mar 6 · 3 nights"),
                      timestamp: Date(), isFromMe: false, otherName: "Maya")
        StayEventCard(event: StayEvent(kind: .cancelled, dateRange: "Mar 3 – Mar 6 · 3 nights"),
                      timestamp: nil, isFromMe: true, otherName: "Maya", state: .pending)
        StayEventCard(event: StayEvent(kind: .hostCancelled, dateRange: "Mar 3 – Mar 6 · 3 nights",
                                       note: "So sorry. The week after is wide open if that helps.",
                                       listingID: "L1"),
                      timestamp: Date(), isFromMe: false, otherName: "Maya",
                      onSeeOtherDates: {})
    }
    .padding(.vertical)
    .background(Color.primaryBackground)
}

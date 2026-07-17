//
//  StayEventCard.swift
//  freebnb
//
//  The centered system card a thread renders for a stay-lifecycle event
//  (requested / accepted / declined / cancelled) in place of the old
//  emoji-prefixed text bubble (item 29). The underlying message keeps its
//  `text`, so this is purely a richer presentation of the same event.
//

import SwiftUI

struct StayEventCard: View {
    let event: StayEvent
    let timestamp: Date?
    /// Pending while the send is in flight, failed if it never committed. Ordinary
    /// events resolve to `.sent` almost immediately.
    var state: MessageState = .sent

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
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let note = event.note, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
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
                .foregroundColor(.secondary)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Sending")
        case .failed:
            Label("Not delivered", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        case .sent:
            if let timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var title: String {
        switch event.kind {
        case .requested: return "Requested to stay"
        case .offered:   return "Offered their place"
        case .accepted:  return "Stay accepted"
        case .declined:  return "Stay request declined"
        case .cancelled: return "Request cancelled"
        case .modified:  return "Dates changed"
        }
    }

    private var iconName: String {
        switch event.kind {
        case .requested: return "calendar"
        case .offered:   return "gift"
        case .accepted:  return "checkmark.circle.fill"
        case .declined:  return "xmark.circle"
        case .cancelled: return "slash.circle"
        case .modified:  return "calendar.badge.clock"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .requested, .modified: return .accent
        // Green like an acceptance rather than accent like a request: an offer is
        // somebody saying yes before being asked, which is good news landing in
        // the thread, not a question being posed.
        case .offered:   return .green
        case .accepted:  return .green
        case .declined, .cancelled: return .secondary
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StayEventCard(event: StayEvent(kind: .requested, dateRange: "Mar 3 – Mar 6 · 3 nights"), timestamp: Date())
        StayEventCard(event: StayEvent(kind: .accepted, dateRange: "Mar 3 – Mar 6 · 3 nights",
                                       note: "Door code is 1988, see you then!"), timestamp: Date())
        StayEventCard(event: StayEvent(kind: .declined, dateRange: "Mar 3 – Mar 6 · 3 nights"), timestamp: Date())
        StayEventCard(event: StayEvent(kind: .cancelled, dateRange: "Mar 3 – Mar 6 · 3 nights"), timestamp: nil, state: .pending)
    }
    .padding(.vertical)
    .background(Color.primaryBackground)
}

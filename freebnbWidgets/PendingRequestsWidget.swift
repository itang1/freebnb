//
//  PendingRequestsWidget.swift
//  freebnbWidgets
//
//  "Pending requests" home-screen widget (feature 40). Surfaces how many stay
//  requests are waiting on the viewer as a host, plus their own requests still
//  waiting on a host. Taps deep link into the Stays tab via `freebnb://stays`.
//

import WidgetKit
import SwiftUI

struct PendingRequestsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PendingRequestsWidget", provider: StayWidgetProvider()) { entry in
            PendingRequestsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "freebnb://stays"))
        }
        .configurationDisplayName("Pending requests")
        .description("Stay requests waiting on you, and yours waiting on a host.")
        .supportedFamilies([.systemSmall])
    }
}

struct PendingRequestsWidgetView: View {
    let snapshot: StayWidgetSnapshot

    private var incoming: Int { snapshot.pendingIncomingCount }
    private var outgoing: Int { snapshot.pendingOutgoingCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill")
                Text("Requests")
                    .fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(WidgetPalette.accent)

            Spacer(minLength: 0)

            Text("\(incoming)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(incoming > 0 ? WidgetPalette.accent : .secondary)
                .contentTransition(.numericText())
            Text(incoming == 1 ? "awaiting your reply" : "awaiting your reply")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if outgoing > 0 {
                Text("\(outgoing) of yours pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("You're all caught up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#Preview("Pending", as: .systemSmall) {
    PendingRequestsWidget()
} timeline: {
    StayWidgetEntry(date: .now, snapshot: .placeholder)
    StayWidgetEntry(date: .now, snapshot: .empty)
}

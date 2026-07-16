//
//  NextTripWidget.swift
//  freebnbWidgets
//
//  "Next trip" home-screen widget (feature 40). Shows the viewer's soonest
//  upcoming or in-progress stay — city, dates, and whether it's live — and deep
//  links into the Stays tab via `freebnb://stays`.
//

import WidgetKit
import SwiftUI

struct NextTripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextTripWidget", provider: StayWidgetProvider()) { entry in
            NextTripWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "freebnb://stays"))
        }
        .configurationDisplayName("Next trip")
        .description("Your next FreeBNB stay at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextTripWidgetView: View {
    let snapshot: StayWidgetSnapshot

    var body: some View {
        if let trip = snapshot.nextTrip {
            TripContent(trip: trip)
        } else {
            EmptyTripContent()
        }
    }
}

private struct TripContent: View {
    let trip: TripSummary

    private var underway: Bool { trip.isUnderway() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: trip.isHost ? "house.fill" : "suitcase.fill")
                Text(underway ? "Happening now" : (trip.isHost ? "Hosting" : "Upcoming trip"))
                    .fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(WidgetPalette.accent)

            Spacer(minLength: 0)

            Text(trip.city)
                .font(.headline)
                .lineLimit(1)
            Text(trip.listingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(trip.dateRangeText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct EmptyTripContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "suitcase")
                .font(.title2)
                .foregroundStyle(WidgetPalette.accent)
            Spacer(minLength: 0)
            Text("No trips yet")
                .font(.headline)
            Text("Find a friend's place to stay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#Preview("Next trip", as: .systemSmall) {
    NextTripWidget()
} timeline: {
    StayWidgetEntry(date: .now, snapshot: .placeholder)
    StayWidgetEntry(date: .now, snapshot: .empty)
}

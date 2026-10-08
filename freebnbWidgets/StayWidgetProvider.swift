//
//  StayWidgetProvider.swift
//  freebnbWidgets
//
//  Feeds both widgets from the App Group snapshot the app writes. No network: the timeline is one entry plus a periodic nudge so day-relative copy stays fresh.
//

import WidgetKit
import Foundation

struct StayWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: StayWidgetSnapshot
}

struct StayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StayWidgetEntry {
        StayWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StayWidgetEntry) -> Void) {
        // The gallery preview shows sample data; a real placed widget shows live data.
        let snapshot = context.isPreview ? .placeholder : StayWidgetSnapshot.read()
        completion(StayWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StayWidgetEntry>) -> Void) {
        let now = Date()
        let entry = StayWidgetEntry(date: now, snapshot: StayWidgetSnapshot.read())
        // The app reloads timelines when data changes, so this is a backstop: refresh at the next hour so day-relative text drifts under an hour.
        let next = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

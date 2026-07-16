//
//  StayWidgetProvider.swift
//  freebnbWidgets
//
//  Feeds both home-screen widgets from the App Group snapshot the app writes.
//  There's no network here — the widget only ever reads the last value the app
//  published — so the timeline is a single entry plus a periodic nudge so
//  "underway" and date-relative copy stay fresh across a day boundary.
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
        // The app reloads timelines whenever the data changes, so this is only a
        // backstop: refresh at the next hour so day-relative text can't drift more
        // than an hour stale if the app never runs.
        let next = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

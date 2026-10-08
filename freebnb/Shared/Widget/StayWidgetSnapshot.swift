//
//  StayWidgetSnapshot.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The payload the app writes to the App Group and widgets read: a small value type with no Firebase or app dependencies, so it compiles into the extension.
//

import Foundation

/// One upcoming or in-progress stay, flattened to just what a widget renders.
struct TripSummary: Codable, Hashable, Sendable {
    var stayID: String
    /// City is always present; `listingLabel` is the home's title when it has one.
    var city: String
    var listingLabel: String
    var checkIn: Date
    var checkOut: Date
    /// Which side of the stay the viewer is on, so copy can say "hosting" vs "trip".
    var isHost: Bool

    var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    /// Mirrors `StayRequest.isUnderway`; duplicated because `StayRequest` isn't compiled into the extension.
    func isUnderway(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard now >= checkIn else { return false }
        let dayAfterCheckout = calendar.date(byAdding: .day, value: 1, to: checkOut) ?? checkOut
        return now < dayAfterCheckout
    }

    /// "Mar 5 – Mar 9", with a widget-local formatter since `AppDateFormatters` is app-only.
    var dateRangeText: String {
        let f = WidgetDateFormatters.shortDay
        return "\(f.string(from: checkIn)) – \(f.string(from: checkOut))"
    }
}

/// The whole snapshot, enough for both the "Next trip" and "Pending requests" widgets from one App Group write.
struct StayWidgetSnapshot: Codable, Hashable, Sendable {
    var nextTrip: TripSummary?
    /// Requests awaiting the viewer's response as a host.
    var pendingIncomingCount: Int
    /// The viewer's own requests still waiting on a host.
    var pendingOutgoingCount: Int
    var generatedAt: Date

    static let empty = StayWidgetSnapshot(
        nextTrip: nil,
        pendingIncomingCount: 0,
        pendingOutgoingCount: 0,
        generatedAt: .distantPast
    )

    /// Sample data for the gallery and previews; never shown with real data behind it.
    static let placeholder = StayWidgetSnapshot(
        nextTrip: TripSummary(
            stayID: "preview",
            city: "Lisbon",
            listingLabel: "Sea-view flat in Alfama",
            checkIn: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
            checkOut: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date(),
            isHost: false
        ),
        pendingIncomingCount: 2,
        pendingOutgoingCount: 1,
        generatedAt: Date()
    )
}

extension StayWidgetSnapshot {
    static let defaultsKey = "stayWidgetSnapshot"

    /// Reads the last published snapshot; `.empty` when none or the App Group is unreachable.
    static func read(from defaults: UserDefaults? = WidgetAppGroup.sharedDefaults) -> StayWidgetSnapshot {
        guard let data = defaults?.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder.widget.decode(StayWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    /// Persists to the shared suite; no-ops if the App Group is unavailable, so the widget keeps its last state.
    func write(to defaults: UserDefaults? = WidgetAppGroup.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder.widget.encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Widget-local formatting

enum WidgetDateFormatters {
    /// "Mar 5" — the compact form used across the widgets.
    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

extension JSONEncoder {
    /// ISO-8601 dates so the payload round-trips identically across processes regardless of locale.
    static let widget: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let widget: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

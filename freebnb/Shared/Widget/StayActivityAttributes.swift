//
//  StayActivityAttributes.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The Live Activity contract for an in-progress stay (feature 21). Shared
//  verbatim between the app (which starts, updates, and ends the activity) and
//  the widget extension (which renders the Lock Screen and Dynamic Island). The
//  static half — where and when — lives in the attributes; the one thing that
//  changes over the stay, its phase, lives in `ContentState`.
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
struct StayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: StayPhase
    }

    let stayID: String
    let city: String
    let listingLabel: String
    let checkIn: Date
    let checkOut: Date
    let isHost: Bool
}
#endif

/// Where a live stay is in its arc. Declared outside the `ActivityKit` guard so
/// non-ActivityKit code (and tests) can reason about it too.
enum StayPhase: String, Codable, Hashable, Sendable {
    /// The guest arrives today but the stay hasn't started yet.
    case arrivingToday
    /// The stay is under way and it isn't checkout day.
    case underway
    /// Checkout happens today.
    case checkoutToday

    /// The phase for a stay at `now`, or nil when there is no live activity to
    /// show (the stay is wholly in the future or already over). `checkIn` and
    /// `checkOut` are local start-of-day dates.
    static func current(
        checkIn: Date,
        checkOut: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StayPhase? {
        let dayAfterCheckout = calendar.date(byAdding: .day, value: 1, to: checkOut) ?? checkOut
        guard now < dayAfterCheckout else { return nil }

        // Not yet check-in day: no phase to report.
        if now < checkIn && !calendar.isDate(now, inSameDayAs: checkIn) {
            return nil
        }
        // The whole check-in day counts as arriving. checkIn is stored as a
        // start-of-day date, so a `now < checkIn` comparison alone would flip
        // the stay to "underway" at midnight, before anyone has arrived.
        if calendar.isDate(now, inSameDayAs: checkIn) {
            return .arrivingToday
        }
        if calendar.isDate(now, inSameDayAs: checkOut) {
            return .checkoutToday
        }
        return .underway
    }
}

extension StayPhase {
    /// Short status line, phrased for whichever side the viewer is on.
    func statusText(isHost: Bool) -> String {
        switch self {
        case .arrivingToday: return isHost ? "Guest arrives today" : "Check in today"
        case .underway:      return isHost ? "Guest is staying" : "You're staying"
        case .checkoutToday: return isHost ? "Guest checks out today" : "Check out today"
        }
    }

    var symbolName: String {
        switch self {
        case .arrivingToday: return "airplane.arrival"
        case .underway:      return "house.fill"
        case .checkoutToday: return "figure.walk.departure"
        }
    }
}

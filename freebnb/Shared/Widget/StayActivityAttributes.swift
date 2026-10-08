//
//  StayActivityAttributes.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The Live Activity contract for an in-progress stay, shared verbatim by the app and the widget extension.
//  The static half (where, when) lives in the attributes; the phase, which changes over the stay, in
//  `ContentState`.
//

import ActivityKit
import Foundation

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

/// Where a live stay is in its arc.
enum StayPhase: String, Codable, Hashable, Sendable {
    /// The guest arrives today but the stay hasn't started yet.
    case arrivingToday
    /// The stay is under way and it isn't checkout day.
    case underway
    /// Checkout happens today.
    case checkoutToday

    /// The phase for a stay at `now`, or nil when there's no live activity (wholly future or over). Dates are
    /// local start-of-day.
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
        // The whole check-in day counts as arriving; comparing `now < checkIn` alone would flip to "underway"
        // at midnight.
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

//
//  StayCounter.swift
//  freebnb
//
//  The frequency half of a circle's policy: `stayCounters/{hostID}_{guestID}`. A circle can
//  cap how often one person books, and rules can't query to count recent requests, so this
//  mirrors `rateLimits`: the client advances a counter in the same commit as the write, the
//  write rule requires it via `getAfter()`, and the counter's rule enforces the cap (with
//  `windowStart` pinned). The guest writes it and both parties read it; the cap comes from
//  the host's circle documents, so tampering only costs the guest their own slots.
//

import FirebaseFirestore
import Foundation

struct StayCounter: Codable, Hashable, Sendable {
    var hostUserID: String
    var guestUserID: String
    /// When the current window opened. Pinned by the rules: update may increment inside it or open a fresh one after it elapses.
    var windowStart: Date
    var count: Int

    /// `{hostID}_{guestID}`; deterministic so the rules find a pair's counter without a query, and pinned to the id fields.
    static func documentID(hostUserID: String, guestUserID: String) -> String {
        "\(hostUserID)_\(guestUserID)"
    }

    /// When the open window ends under `cap`, i.e. when slots come back.
    func windowEnd(cap: StayFrequencyCap, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: cap.periodDays, to: windowStart) ?? windowStart
    }

    /// Slots spent as of `now`; an elapsed window has spent none.
    func spent(cap: StayFrequencyCap, now: Date = Date(), calendar: Calendar = .current) -> Int {
        now >= windowEnd(cap: cap, calendar: calendar) ? 0 : count
    }

    /// The value this counter takes when a request is created at `now`; the two branches the rules allow.
    func advanced(cap: StayFrequencyCap, now: Date = Date(), calendar: Calendar = .current) -> StayCounter {
        var next = self
        if now >= windowEnd(cap: cap, calendar: calendar) {
            next.windowStart = now
            next.count = 1
        } else {
            next.count = count + 1
        }
        return next
    }

    /// The counter a guest's first-ever request to this host writes.
    static func opening(hostUserID: String, guestUserID: String, now: Date = Date()) -> StayCounter {
        StayCounter(hostUserID: hostUserID, guestUserID: guestUserID, windowStart: now, count: 1)
    }
}

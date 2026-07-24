//
//  StayCounter.swift
//  freebnb
//
//  The frequency half of a circle's policy: `stayCounters/{hostID}_{guestID}`.
//
//  A circle can cap how often one person books ("2 stays every 30 days"), and
//  security rules cannot run a query, so there is no way to count a guest's
//  recent requests at write time. The app already solved this shape once, for
//  message rate limiting: the client advances a counter document in the same
//  commit as the write it governs, the write rule requires the advance through
//  `getAfter()`, and the counter's own rule enforces the cap. `rateLimits` is
//  the precedent this mirrors, including the pinned `windowStart` that stops the
//  window being slid forward to dodge the cap.
//
//  The counter is written by the guest and read by both parties. That is safe
//  because the cap it is checked against comes from the host's circle documents,
//  which the guest cannot write — a guest who tampers with their own counter can
//  only refuse themselves slots they were owed.
//

import FirebaseFirestore
import Foundation

struct StayCounter: Codable, Hashable, Sendable {
    var hostUserID: String
    var guestUserID: String
    /// When the current window opened. Pinned by the rules for the life of the
    /// window: an update may increment inside it or open a fresh one once it has
    /// elapsed, never move this forward to buy headroom.
    var windowStart: Date
    var count: Int

    /// `{hostID}_{guestID}`. Deterministic so the rules can find the counter for
    /// a pair without a query, and pinned by the rules to the two id fields so a
    /// guest cannot spend someone else's slots.
    static func documentID(hostUserID: String, guestUserID: String) -> String {
        "\(hostUserID)_\(guestUserID)"
    }

    /// When the open window ends under `cap`, i.e. when the guest's slots come
    /// back.
    func windowEnd(cap: StayFrequencyCap, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: cap.periodDays, to: windowStart) ?? windowStart
    }

    /// How many slots this counter has actually spent as of `now`. A window that
    /// has already elapsed has spent none: the next request opens a fresh one.
    func spent(cap: StayFrequencyCap, now: Date = Date(), calendar: Calendar = .current) -> Int {
        now >= windowEnd(cap: cap, calendar: calendar) ? 0 : count
    }

    /// The value this counter takes when a request is created at `now` — the
    /// same two branches the rules allow, so the client's write is never one the
    /// rules would have to reject.
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

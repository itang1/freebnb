//
//  AvailabilityCalendar.swift
//  freebnb
//
//  The arithmetic behind the availability month grid (feature 16), kept apart
//  from the views that draw it so the tricky part — turning a tapped day back
//  into a set of merged ranges — is unit-tested rather than eyeballed.
//
//  A `DateRange` is half-open: `start` is blocked, `end` is not. That is what
//  `DateRange.overlaps(checkIn:checkOut:)` already assumes (`checkIn < end`), and
//  what makes a single blocked day the range `[D, D+1)`. Everything here converts
//  between that representation and a flat set of blocked days, because a set is
//  the shape a tappable grid actually wants: toggling one day out of the middle of
//  a range is a split, a merge, or a no-op depending on where it lands, and none
//  of that survives contact with range surgery.
//

import Foundation

enum AvailabilityCalendar {
    /// Every day covered by `ranges`, normalised to the start of its day.
    ///
    /// A range whose `end` precedes its `start` contributes nothing rather than
    /// looping: those documents shouldn't exist, but this runs on data a modified
    /// client could have written.
    static func blockedDays(in ranges: [DateRange], calendar: Calendar = .current) -> Set<Date> {
        var days: Set<Date> = []
        for range in ranges {
            var day = calendar.startOfDay(for: range.start)
            let end = calendar.startOfDay(for: range.end)
            while day < end {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    /// The inverse: consecutive days collapse into one half-open range, ordered
    /// earliest first. `days` is expected to hold start-of-day values.
    static func ranges(from days: Set<Date>, calendar: Calendar = .current) -> [DateRange] {
        let sorted = days.sorted()
        var ranges: [DateRange] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var last = start
            // Walk forward while each day is exactly one after the previous.
            while index + 1 < sorted.count,
                  let next = calendar.date(byAdding: .day, value: 1, to: last),
                  calendar.isDate(sorted[index + 1], inSameDayAs: next) {
                index += 1
                last = sorted[index]
            }
            guard let end = calendar.date(byAdding: .day, value: 1, to: last) else { break }
            ranges.append(DateRange(start: start, end: end))
            index += 1
        }
        return ranges
    }

    /// `existing` ranges with `added` days folded in — the merge behind "apply to
    /// all my homes". Additive and deduped by day: a home keeps every date it had
    /// blocked and gains the new ones, so stamping travel dates across homes can't
    /// erase a home's own closures. Order-independent, and idempotent, so re-running
    /// it changes nothing.
    static func merging(_ existing: [DateRange], adding added: Set<Date>, calendar: Calendar = .current) -> [DateRange] {
        ranges(from: blockedDays(in: existing, calendar: calendar).union(added), calendar: calendar)
    }

    /// Ranges that have not finished yet. The editor drops the rest on save: a
    /// blocked week from last year is noise a host has to scroll past, and it can
    /// no longer affect a request.
    static func upcoming(_ ranges: [DateRange], now: Date = Date()) -> [DateRange] {
        ranges.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    /// The day cells of `month`, padded with nils for the weekdays before the 1st
    /// so the first cell lands under the right weekday header. The number of
    /// leading blanks respects `calendar.firstWeekday`, which is not Sunday
    /// everywhere.
    static func monthGrid(for month: Date, calendar: Calendar = .current) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }

        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        return cells
    }

    /// Weekday initials in the calendar's own week order, for the grid header.
    static func weekdayInitials(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return (0..<symbols.count).map { symbols[($0 + offset) % symbols.count] }
    }

    /// A day is in the past once the day it belongs to has ended. Today is not
    /// past: a host can still block tonight.
    static func isPast(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    /// Adds `day` to the blocked set, or removes it if it was already there.
    /// Past days are left alone — the grid disables them, and this is the second
    /// place that promise is kept.
    static func toggling(
        _ day: Date,
        in days: Set<Date>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Set<Date> {
        let normalized = calendar.startOfDay(for: day)
        guard !isPast(normalized, now: now, calendar: calendar) else { return days }
        var updated = days
        if updated.contains(normalized) {
            updated.remove(normalized)
        } else {
            updated.insert(normalized)
        }
        return updated
    }

    /// The nights a stay actually occupies: every day in `[checkIn, checkOut)`.
    /// The check-out day is not one of them — the guest leaves that morning — which
    /// is why a stay may end on a day the host has blocked.
    static func nights(from checkIn: Date, to checkOut: Date, calendar: Calendar = .current) -> [Date] {
        var nights: [Date] = []
        var day = calendar.startOfDay(for: checkIn)
        let end = calendar.startOfDay(for: checkOut)
        while day < end {
            nights.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return nights
    }

    /// Whether a guest could actually stay `[checkIn, checkOut)`: at least one
    /// night, and no night the host has ruled out. The guest-side grid asks this
    /// before it will draw a span, so a selection that the request sheet would
    /// reject can't be made in the first place.
    static func isStaySelectable(
        checkIn: Date,
        checkOut: Date,
        unavailableDays: Set<Date>,
        calendar: Calendar = .current
    ) -> Bool {
        let nights = nights(from: checkIn, to: checkOut, calendar: calendar)
        guard !nights.isEmpty else { return false }
        return !nights.contains(where: unavailableDays.contains)
    }

    /// Days of turnover padding a buffer of `hours` implies, on a day-granular
    /// calendar. Rounds up, because any positive buffer rules out same-day
    /// turnover: even an hour means the day a guest checks out is not a day the
    /// next guest may check in.
    static func bufferDays(forHours hours: Int) -> Int {
        hours > 0 ? (hours + 23) / 24 : 0
    }

    /// Each booked range grown by `bufferHours` of turnover on both sides, then
    /// merged. This is what the published calendar carries in place of the raw
    /// stays: the day before a check-in and the day after a checkout read as
    /// unavailable, indistinguishable from any other closed day, so a guest still
    /// learns only that a date is spoken for and never why. A zero buffer returns
    /// the ranges untouched, which is exactly the pre-buffer behaviour.
    static func buffered(_ ranges: [DateRange], bufferHours: Int, calendar: Calendar = .current) -> [DateRange] {
        let days = bufferDays(forHours: bufferHours)
        guard days > 0 else { return ranges }
        let padded = ranges.map { range in
            DateRange(
                start: calendar.date(byAdding: .day, value: -days, to: range.start) ?? range.start,
                end: calendar.date(byAdding: .day, value: days, to: range.end) ?? range.end
            )
        }
        // Round-trip through the day set so overlapping padded ranges merge, the
        // same normalisation `merging` relies on.
        return self.ranges(from: blockedDays(in: padded, calendar: calendar), calendar: calendar)
    }

    /// The next `monthCount` months starting with the one containing `from`, which
    /// is how far ahead the grid lets a host or guest look.
    static func months(from: Date = Date(), count: Int, calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: from)?.start else { return [] }
        return (0..<count).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }
}

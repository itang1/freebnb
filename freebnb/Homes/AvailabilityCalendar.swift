//
//  AvailabilityCalendar.swift
//  freebnb
//
//  The arithmetic behind the availability month grid, apart from the views so the
//  tricky part (turning a tapped day back into merged ranges) is unit-tested.
//
//  A `DateRange` is half-open: `start` is blocked, `end` is not, so a single blocked
//  day is `[D, D+1)`. Everything converts between that and a flat set of days, the
//  shape a tappable grid wants (toggling a day is a split, merge or no-op).
//

import Foundation

enum AvailabilityCalendar {
    /// Every day covered by `ranges`, normalised to start of day. A range ending
    /// before it starts contributes nothing rather than looping (modified clients could write one).
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

    /// The inverse: consecutive days collapse into half-open ranges, earliest first. `days` holds start-of-day values.
    static func ranges(from days: Set<Date>, calendar: Calendar = .current) -> [DateRange] {
        let sorted = days.sorted()
        var ranges: [DateRange] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var last = start
            // Walk forward while each day follows the previous.
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

    /// `existing` ranges with `added` days folded in, behind "apply to all my homes".
    /// Additive, deduped by day, order-independent and idempotent, so a home keeps its own closures.
    static func merging(_ existing: [DateRange], adding added: Set<Date>, calendar: Calendar = .current) -> [DateRange] {
        ranges(from: blockedDays(in: existing, calendar: calendar).union(added), calendar: calendar)
    }

    /// Ranges that haven't finished yet; the editor drops the rest on save as noise that can't affect a request.
    static func upcoming(_ ranges: [DateRange], now: Date = Date()) -> [DateRange] {
        ranges.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    /// The day cells of `month`, nil-padded for weekdays before the 1st per `calendar.firstWeekday`.
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

    /// A day is past once it has ended; today is not past (a host can still block tonight).
    static func isPast(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    /// Adds `day` to the blocked set or removes it. Past days are left alone, a second guard behind the grid.
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

    /// The nights a stay occupies: every day in `[checkIn, checkOut)`. The check-out
    /// day isn't one, so a stay may end on a blocked day.
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

    /// Whether a guest could stay `[checkIn, checkOut)`: at least one night, none ruled out.
    /// The guest grid asks before drawing a span.
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

    /// Days of turnover padding for `hours` on a day-granular calendar, rounded up
    /// since any positive buffer rules out same-day turnover.
    static func bufferDays(forHours hours: Int) -> Int {
        hours > 0 ? (hours + 23) / 24 : 0
    }

    /// Each booked range grown by `bufferHours` of turnover on both sides, then
    /// merged; this is what the published calendar carries instead of raw stays, so
    /// the padded days read as any closed day. A zero buffer returns the ranges untouched.
    static func buffered(_ ranges: [DateRange], bufferHours: Int, calendar: Calendar = .current) -> [DateRange] {
        let days = bufferDays(forHours: bufferHours)
        guard days > 0 else { return ranges }
        let padded = ranges.map { range in
            DateRange(
                start: calendar.date(byAdding: .day, value: -days, to: range.start) ?? range.start,
                end: calendar.date(byAdding: .day, value: days, to: range.end) ?? range.end
            )
        }
        // Round-trip through the day set so overlapping padded ranges merge.
        return self.ranges(from: blockedDays(in: padded, calendar: calendar), calendar: calendar)
    }

    /// The next `monthCount` months from the one containing `from`: how far ahead the grid looks.
    static func months(from: Date = Date(), count: Int, calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: from)?.start else { return [] }
        return (0..<count).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }
}

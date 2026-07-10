//
//  AvailabilityCalendarTests.swift
//  freebnbTests
//
//  Covers the availability calendar's arithmetic (feature 16): the round trip
//  between stored `DateRange`s and the flat set of days a tappable grid needs.
//
//  `DateRange` is half-open — `start` is blocked, `end` is not — which is what
//  `overlaps(checkIn:checkOut:)` assumes. Every off-by-one here is a day a guest
//  could book into a blocked night, or a day a host blocked without meaning to,
//  so the boundaries are pinned explicitly.
//

import Foundation
import Testing
@testable import freebnb

/// A fixed calendar in UTC. `Calendar.current` would make these assertions depend
/// on the machine's time zone and first weekday.
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    calendar.firstWeekday = 1 // Sunday
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    // A fabricated date that doesn't resolve is a bug in the test, not the code.
    guard let date = calendar.date(from: components) else {
        fatalError("could not build \(year)-\(month)-\(day)")
    }
    return date
}

private func date(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    day(year, month, dayOfMonth, in: utc)
}

/// `CalendarInvite` formats DTSTART/DTEND in the device's own time zone, so the
/// iCalendar tests must build their dates there too. A UTC midnight is the
/// previous afternoon in California, and would format as the day before.
private func localDate(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    day(year, month, dayOfMonth, in: .current)
}

struct BlockedDayRoundTripTests {
    /// A half-open range covers its start and stops before its end: blocking
    /// Mar 5 – Mar 8 blocks three nights, not four.
    @Test func rangeExpandsToItsDaysExcludingTheEnd() {
        let range = DateRange(start: date(2026, 3, 5), end: date(2026, 3, 8))
        let days = AvailabilityCalendar.blockedDays(in: [range], calendar: utc)
        #expect(days == [date(2026, 3, 5), date(2026, 3, 6), date(2026, 3, 7)])
    }

    /// A single blocked day is `[D, D+1)`, which is the shape a tapped grid cell
    /// has to produce.
    @Test func singleDayRoundTripsThroughItsHalfOpenRange() {
        let days: Set<Date> = [date(2026, 3, 5)]
        let ranges = AvailabilityCalendar.ranges(from: days, calendar: utc)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[0].end == date(2026, 3, 6))
        #expect(AvailabilityCalendar.blockedDays(in: ranges, calendar: utc) == days)
    }

    @Test func consecutiveDaysMergeIntoOneRange() {
        let days: Set<Date> = [date(2026, 3, 5), date(2026, 3, 6), date(2026, 3, 7)]
        let ranges = AvailabilityCalendar.ranges(from: days, calendar: utc)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[0].end == date(2026, 3, 8))
    }

    /// A gap of one day is enough to split. Merging across it would block a night
    /// the host left open.
    @Test func nonConsecutiveDaysStayAsSeparateRanges() {
        let days: Set<Date> = [date(2026, 3, 5), date(2026, 3, 7)]
        let ranges = AvailabilityCalendar.ranges(from: days, calendar: utc)
        #expect(ranges.count == 2)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[1].start == date(2026, 3, 7))
    }

    /// Untoggling a day out of the middle of a block splits it. This is the case
    /// range surgery gets wrong and a day set gets right for free.
    @Test func unblockingTheMiddleOfARangeSplitsIt() {
        let original = DateRange(start: date(2026, 3, 5), end: date(2026, 3, 10))
        var days = AvailabilityCalendar.blockedDays(in: [original], calendar: utc)
        days = AvailabilityCalendar.toggling(date(2026, 3, 7), in: days, now: date(2026, 1, 1), calendar: utc)

        let ranges = AvailabilityCalendar.ranges(from: days, calendar: utc)
        #expect(ranges.count == 2)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[0].end == date(2026, 3, 7))
        #expect(ranges[1].start == date(2026, 3, 8))
        #expect(ranges[1].end == date(2026, 3, 10))
    }

    /// Blocking the day between two blocks fuses them into one.
    @Test func blockingTheGapBetweenTwoRangesMergesThem() {
        var days: Set<Date> = [date(2026, 3, 5), date(2026, 3, 7)]
        days = AvailabilityCalendar.toggling(date(2026, 3, 6), in: days, now: date(2026, 1, 1), calendar: utc)

        let ranges = AvailabilityCalendar.ranges(from: days, calendar: utc)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[0].end == date(2026, 3, 8))
    }

    @Test func rangesComeBackInChronologicalOrder() {
        let days: Set<Date> = [date(2026, 5, 1), date(2026, 3, 5), date(2026, 4, 2)]
        let starts = AvailabilityCalendar.ranges(from: days, calendar: utc).map(\.start)
        #expect(starts == [date(2026, 3, 5), date(2026, 4, 2), date(2026, 5, 1)])
    }

    @Test func emptyDaysProduceNoRanges() {
        #expect(AvailabilityCalendar.ranges(from: [], calendar: utc).isEmpty)
    }

    /// A modified client could write `end` before `start`. Expanding it must
    /// terminate rather than loop forever.
    @Test func invertedRangeContributesNothing() {
        let inverted = DateRange(start: date(2026, 3, 8), end: date(2026, 3, 5))
        #expect(AvailabilityCalendar.blockedDays(in: [inverted], calendar: utc).isEmpty)
    }

    /// An overlap between two stored ranges must not double-count a day; the day
    /// set absorbs it, and the ranges come back merged.
    @Test func overlappingStoredRangesCollapse() {
        let a = DateRange(start: date(2026, 3, 5), end: date(2026, 3, 8))
        let b = DateRange(start: date(2026, 3, 7), end: date(2026, 3, 10))
        let ranges = AvailabilityCalendar.ranges(
            from: AvailabilityCalendar.blockedDays(in: [a, b], calendar: utc),
            calendar: utc
        )
        #expect(ranges.count == 1)
        #expect(ranges[0].start == date(2026, 3, 5))
        #expect(ranges[0].end == date(2026, 3, 10))
    }
}

struct TogglePastDayTests {
    private let now = date(2026, 3, 10)

    /// Today is not past — a host can still block tonight.
    @Test func todayIsNotPast() {
        #expect(!AvailabilityCalendar.isPast(now, now: now, calendar: utc))
        #expect(AvailabilityCalendar.isPast(date(2026, 3, 9), now: now, calendar: utc))
        #expect(!AvailabilityCalendar.isPast(date(2026, 3, 11), now: now, calendar: utc))
    }

    /// The grid disables past cells; this is the second place that promise is kept,
    /// so a stray tap can never rewrite history.
    @Test func togglingAPastDayIsANoOp() {
        let days: Set<Date> = [date(2026, 3, 20)]
        let after = AvailabilityCalendar.toggling(date(2026, 3, 1), in: days, now: now, calendar: utc)
        #expect(after == days)
    }

    @Test func togglingIsItsOwnInverseForAFutureDay() {
        let day = date(2026, 3, 20)
        let once = AvailabilityCalendar.toggling(day, in: [], now: now, calendar: utc)
        #expect(once == [day])
        let twice = AvailabilityCalendar.toggling(day, in: once, now: now, calendar: utc)
        #expect(twice.isEmpty)
    }

    /// Whatever time of day the tap carries, the stored value is the day itself.
    @Test func togglingNormalizesToTheStartOfTheDay() throws {
        let afternoon = try #require(utc.date(byAdding: .hour, value: 15, to: date(2026, 3, 20)))
        let days = AvailabilityCalendar.toggling(afternoon, in: [], now: now, calendar: utc)
        #expect(days == [date(2026, 3, 20)])
    }

    @Test func upcomingDropsFinishedRangesAndSortsTheRest() {
        let past = DateRange(start: date(2026, 3, 1), end: date(2026, 3, 3))
        let later = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 3))
        let sooner = DateRange(start: date(2026, 3, 20), end: date(2026, 3, 22))
        let upcoming = AvailabilityCalendar.upcoming([later, past, sooner], now: now)
        #expect(upcoming.map(\.start) == [sooner.start, later.start])
    }
}

struct MonthGridTests {
    /// March 2026 starts on a Sunday, so with a Sunday-first week there are no
    /// leading blanks and the grid is exactly its 31 days.
    @Test func monthStartingOnTheFirstWeekdayHasNoLeadingBlanks() {
        let cells = AvailabilityCalendar.monthGrid(for: date(2026, 3, 15), calendar: utc)
        #expect(cells.count == 31)
        #expect(cells[0] == date(2026, 3, 1))
        #expect(cells[30] == date(2026, 3, 31))
    }

    /// April 2026 starts on a Wednesday: three blanks before the 1st, so the first
    /// cell lands under the right weekday header.
    @Test func monthIsPaddedToStartUnderTheCorrectWeekday() {
        let cells = AvailabilityCalendar.monthGrid(for: date(2026, 4, 10), calendar: utc)
        #expect(cells.prefix(3).allSatisfy { $0 == nil })
        #expect(cells[3] == date(2026, 4, 1))
        #expect(cells.count == 33)
    }

    /// A week's worth of headers, rotated to the calendar's own first weekday.
    @Test func weekdayInitialsFollowTheCalendarsFirstWeekday() {
        var mondayFirst = utc
        mondayFirst.firstWeekday = 2
        let sunday = AvailabilityCalendar.weekdayInitials(calendar: utc)
        let monday = AvailabilityCalendar.weekdayInitials(calendar: mondayFirst)
        #expect(sunday.count == 7)
        #expect(monday.count == 7)
        #expect(monday.first == sunday[1])
        #expect(monday.last == sunday[0])
    }

    @Test func monthsRunForwardFromTheStartOfTheGivenMonth() {
        let months = AvailabilityCalendar.months(from: date(2026, 3, 15), count: 3, calendar: utc)
        #expect(months == [date(2026, 3, 1), date(2026, 4, 1), date(2026, 5, 1)])
    }
}

struct CalendarInviteTests {
    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// A calendar with nothing in it is not worth sharing, and the button that
    /// would offer it keys off this nil.
    @Test func noEventsProducesNoFile() {
        #expect(CalendarInvite.icsFile(events: [], filename: "Empty.ics") == nil)
    }

    @Test func everyBlockedPeriodBecomesItsOwnEvent() throws {
        let events = (0..<3).map { index in
            CalendarInvite.Event(
                uid: "listing-blocked-\(index)",
                title: "Unavailable",
                location: nil,
                notes: nil,
                startDay: localDate(2026, 3, 5 + index * 5),
                endDay: localDate(2026, 3, 7 + index * 5)
            )
        }
        let url = try #require(CalendarInvite.icsFile(events: events, filename: "AvailabilityTest.ics"))
        let ics = try contents(url)

        #expect(ics.components(separatedBy: "BEGIN:VEVENT").count - 1 == 3)
        #expect(ics.components(separatedBy: "END:VEVENT").count - 1 == 3)
        #expect(ics.hasPrefix("BEGIN:VCALENDAR"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        // Distinct UIDs, or a calendar app collapses the events into one.
        #expect(ics.contains("UID:listing-blocked-0@freebnb.app"))
        #expect(ics.contains("UID:listing-blocked-2@freebnb.app"))
    }

    /// The single-event overload still writes what the stay logistics card expects.
    @Test func singleEventOverloadStillProducesOneEvent() throws {
        let url = try #require(CalendarInvite.icsFile(
            uid: "stay-1",
            title: "Stay with Priya",
            location: "Portland, OR",
            notes: "Arrive after 4pm",
            startDay: localDate(2026, 3, 5),
            endDay: localDate(2026, 3, 9)
        ))
        let ics = try contents(url)
        #expect(ics.components(separatedBy: "BEGIN:VEVENT").count - 1 == 1)
        #expect(ics.contains("DTSTART;VALUE=DATE:20260305"))
        #expect(ics.contains("DTEND;VALUE=DATE:20260309"))
        #expect(ics.contains("SUMMARY:Stay with Priya"))
        #expect(ics.contains("LOCATION:Portland\\, OR"))
    }

    /// The two exports must not share a path in the temporary directory, or a
    /// stale stay rides out under the availability export's name.
    @Test func stayAndAvailabilityExportsUseDistinctFiles() throws {
        let stay = try #require(CalendarInvite.icsFile(
            uid: "stay-1", title: "Stay", location: nil, notes: nil,
            startDay: localDate(2026, 3, 5), endDay: localDate(2026, 3, 9)
        ))
        let availability = try #require(CalendarInvite.icsFile(
            events: [CalendarInvite.Event(
                uid: "blocked-0", title: "Unavailable", location: nil, notes: nil,
                startDay: localDate(2026, 3, 5), endDay: localDate(2026, 3, 6)
            )],
            filename: "FreeBNB-Availability.ics"
        ))
        #expect(stay != availability)
    }
}

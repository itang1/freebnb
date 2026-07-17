//
//  AvailabilityStanceTests.swift
//  freebnbTests
//
//  Covers the host's standing availability (feature 42): the positive half of
//  availability, as against the negative `blockedDateRanges` that
//  AvailabilityCalendarTests pins.
//
//  The thing worth testing here is the silence. A listing whose host has never
//  answered must read as "nobody said", never as a year of free dates — that
//  conflation is the bug the stance exists to fix, and it is invisible in the UI
//  until a guest asks for a date the host never offered.
//

import Foundation
import Testing
@testable import freebnb

/// Fixed UTC, for the same reason AvailabilityCalendarTests uses one: these
/// assertions must not depend on the machine's time zone.
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    calendar.firstWeekday = 1
    return calendar
}

private func date(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = dayOfMonth
    guard let date = utc.date(from: components) else {
        fatalError("could not build \(year)-\(month)-\(dayOfMonth)")
    }
    return date
}

/// "Now" for every test in this file. Fixed so the pruning of past windows is
/// deterministic rather than a function of the wall clock.
private let now = date(2026, 3, 15)

private func home(
    stance: AvailabilityStance? = nil,
    open: [DateRange]? = nil
) -> Home {
    var home = HomeFixture.make()
    home.availabilityStance = stance
    home.openDateRanges = open
    return home
}

struct AvailabilityStanceDefaultTests {
    @Test func absentStanceReadsAsAskNotYes() {
        #expect(home().stance == .ask)
        // The whole point: silence is not a standing yes, so it must not survive
        // the "Open to Friends" filter. Before the stance existed, this listing
        // claimed every date for a year purely by having blocked nothing.
        #expect(home().hasStandingYes(now: now) == false)
    }

    /// A decode failure drops the listing from the feed entirely (A5), so a stance
    /// a future build added must degrade to `.ask`, not delete someone's home.
    @Test func unknownStanceDecodesToAskRatherThanDroppingTheListing() throws {
        let json = Data("""
        {
          "hostUserID": "h", "hostName": "Host",
          "address": {"city": "Town", "state": "CA", "zip": "00000"},
          "sleeping": {"numGuestRooms": 1, "arrangements": {"bed": 1}},
          "guestPolicy": {"maxGuests": 2, "maxStayDays": 7, "kidsAllowed": true, "guestPetsAllowed": false},
          "amenities": {
            "hasAC": false, "hasHeating": false, "hasKitchen": false, "hasFridgeSpace": false,
            "hasMicrowave": false, "hasTV": false, "hasWifi": false,
            "hasPrivateGuestBathroom": false, "hostHasPets": false, "parkingDetails": "",
            "hasInUnitLaundry": false, "hasCoinLaundryNearby": false,
            "providesPillows": false, "providesBlankets": false, "providesTowels": false,
            "providesToiletries": false, "foodProvision": "none"
          },
          "availabilityStance": "someStanceFromTheFuture"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(Home.self, from: json)
        #expect(decoded.stance == .ask)
    }
}

struct StandingYesTests {
    @Test func alwaysCarriesAStandingYes() {
        #expect(home(stance: .always).hasStandingYes(now: now))
    }

    @Test func pausedAndAskCarryNoStandingYes() {
        #expect(home(stance: .paused).hasStandingYes(now: now) == false)
        #expect(home(stance: .ask).hasStandingYes(now: now) == false)
    }

    @Test func windowsCarryAStandingYesOnlyWhileOneIsStillAhead() {
        let future = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 10))
        #expect(home(stance: .windows, open: [future]).hasStandingYes(now: now))

        // Every window named has already ended: the host's yes was about dates
        // that are gone, so it is no longer a yes anyone can act on.
        let past = DateRange(start: date(2026, 1, 1), end: date(2026, 1, 10))
        #expect(home(stance: .windows, open: [past]).hasStandingYes(now: now) == false)

        // And a stance of `.windows` naming no windows is not a yes either.
        #expect(home(stance: .windows, open: nil).hasStandingYes(now: now) == false)
    }
}

struct OpenWindowsTests {
    @Test func windowsAreReadOnlyForTheWindowsStance() {
        let range = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 10))
        // A host who drew windows and then switched to "always" keeps the dates
        // on the document (the editor preserves them), but nothing should read
        // them as a limit — `.always` is open to any unblocked date.
        #expect(home(stance: .always, open: [range]).openWindows(now: now).isEmpty)
        #expect(home(stance: .ask, open: [range]).openWindows(now: now).isEmpty)
        #expect(home(stance: .windows, open: [range]).openWindows(now: now).count == 1)
    }

    @Test func windowsDropThePastAndSortEarliestFirst() {
        let past = DateRange(start: date(2026, 1, 1), end: date(2026, 1, 10))
        let june = DateRange(start: date(2026, 6, 1), end: date(2026, 6, 10))
        let april = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 10))

        let windows = home(stance: .windows, open: [june, past, april]).openWindows(now: now)
        #expect(windows.map(\.start) == [date(2026, 4, 1), date(2026, 6, 1)])
    }
}

struct WithinOpenWindowTests {
    @Test func aStayInsideOneOfferedWindowIsWithinItBoundariesIncluded() {
        let window = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 10))
        let listing = home(stance: .windows, open: [window])

        #expect(listing.isWithinOpenWindow(checkIn: date(2026, 4, 2), checkOut: date(2026, 4, 5), now: now))
        // The window's own bounds are inside it: `end` is exclusive as a *day*, so
        // a checkout on the 10th is the guest leaving the morning after the last
        // offered night, which is exactly what the host drew.
        #expect(listing.isWithinOpenWindow(checkIn: date(2026, 4, 1), checkOut: date(2026, 4, 10), now: now))
    }

    @Test func aStayOutsideOverhangingOrStraddlingWindowsIsNotWithinThem() {
        let april = DateRange(start: date(2026, 4, 1), end: date(2026, 4, 10))
        let june = DateRange(start: date(2026, 6, 1), end: date(2026, 6, 10))
        let listing = home(stance: .windows, open: [april, june])

        // Wholly elsewhere.
        #expect(listing.isWithinOpenWindow(checkIn: date(2026, 5, 1), checkOut: date(2026, 5, 3), now: now) == false)
        // Starts inside April but runs past its end: the tail is a stretch the
        // host never offered, so the stay as a whole isn't what they agreed to.
        #expect(listing.isWithinOpenWindow(checkIn: date(2026, 4, 8), checkOut: date(2026, 4, 14), now: now) == false)
        // Spans April *and* June, and therefore the two months between them that
        // the host deliberately did not offer.
        #expect(listing.isWithinOpenWindow(checkIn: date(2026, 4, 5), checkOut: date(2026, 6, 5), now: now) == false)
    }

    /// `.always` is open to everything, but it says so through `stance`, not by
    /// claiming a window it never drew — a caller must not read `false` here as
    /// "this host is closed".
    @Test func nothingIsWithinAnOpenWindowWhenTheHostNamedNone() {
        #expect(home(stance: .always).isWithinOpenWindow(checkIn: date(2026, 4, 1), checkOut: date(2026, 4, 5), now: now) == false)
        #expect(home(stance: .ask).isWithinOpenWindow(checkIn: date(2026, 4, 1), checkOut: date(2026, 4, 5), now: now) == false)
    }
}

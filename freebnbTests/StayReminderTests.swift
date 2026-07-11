//
//  StayReminderTests.swift
//  freebnbTests
//
//  The scheduling *decisions* behind feature 22's local reminders: which
//  reminders exist, when they fire, and whose point of view the copy takes.
//  UNUserNotificationCenter is never touched here — that's the whole point of
//  keeping `StayReminder.reminders(for:...)` pure.
//

import Foundation
import Testing
@testable import freebnb

private let cal = Calendar.current
private let host = "host-1"
private let guest = "guest-1"

/// A start-of-day `n` days from `base`, matching how check-in/out are stored.
private func day(_ n: Int, from base: Date) -> Date {
    cal.startOfDay(for: cal.date(byAdding: .day, value: n, to: base)!)
}

private func stay(
    id: String = "stay-1",
    checkInOffset: Int,
    checkOutOffset: Int,
    status: StayRequestStatus = .accepted,
    from base: Date
) -> StayRequest {
    StayRequest(
        id: id,
        listingID: "listing-1",
        listingCity: "Portland",
        listingHostName: "Sam",
        hostUserID: host,
        guestUserID: guest,
        checkIn: day(checkInOffset, from: base),
        checkOut: day(checkOutOffset, from: base),
        status: status
    )
}

@Suite struct StayReminderTests {

    @Test func acceptedFutureStayGetsCheckInAndCheckoutReminders() {
        let now = Date()
        let s = stay(checkInOffset: 5, checkOutOffset: 8, from: now)
        let reminders = StayReminder.reminders(for: [s], viewerID: guest, now: now)

        #expect(reminders.count == 2)
        #expect(Set(reminders.map(\.kind)) == [.checkIn, .checkOut])
    }

    @Test func checkInFiresEveningBeforeAndCheckoutFiresMorningOf() {
        let now = Date()
        let s = stay(checkInOffset: 5, checkOutOffset: 8, from: now)
        let reminders = StayReminder.reminders(for: [s], viewerID: guest, now: now)

        let checkIn = try! #require(reminders.first { $0.kind == .checkIn })
        let checkInComps = cal.dateComponents([.day, .hour], from: checkIn.fireDate)
        #expect(checkInComps.hour == StayReminder.checkInHour)
        // The evening before, i.e. the day before check-in.
        #expect(cal.isDate(checkIn.fireDate, inSameDayAs: day(4, from: now)))

        let checkOut = try! #require(reminders.first { $0.kind == .checkOut })
        #expect(cal.component(.hour, from: checkOut.fireDate) == StayReminder.checkOutHour)
        #expect(cal.isDate(checkOut.fireDate, inSameDayAs: day(8, from: now)))
    }

    @Test func inProgressStayOnlySchedulesCheckout() {
        // Checked in two days ago, checks out in two days: the evening-before
        // check-in reminder is in the past, so only checkout survives.
        let now = Date()
        let s = stay(checkInOffset: -2, checkOutOffset: 2, from: now)
        let reminders = StayReminder.reminders(for: [s], viewerID: guest, now: now)

        #expect(reminders.map(\.kind) == [.checkOut])
    }

    @Test func nonAcceptedStaysAreIgnored() {
        let now = Date()
        for status in [StayRequestStatus.pending, .completed, .declined, .cancelled] {
            let s = stay(checkInOffset: 5, checkOutOffset: 8, status: status, from: now)
            #expect(StayReminder.reminders(for: [s], viewerID: guest, now: now).isEmpty)
        }
    }

    @Test func copyTakesTheViewersSide() {
        let now = Date()
        let s = stay(checkInOffset: 5, checkOutOffset: 8, from: now)

        let asGuest = StayReminder.reminders(for: [s], viewerID: guest, now: now)
        let asHost = StayReminder.reminders(for: [s], viewerID: host, now: now)

        let guestCheckIn = try! #require(asGuest.first { $0.kind == .checkIn })
        let hostCheckIn = try! #require(asHost.first { $0.kind == .checkIn })
        #expect(guestCheckIn.title == "Check-in is tomorrow")
        #expect(hostCheckIn.title == "A guest arrives tomorrow")
        #expect(guestCheckIn.body != hostCheckIn.body)
    }

    @Test func identifiersAreStablePerStayAndKind() {
        let now = Date()
        let s = stay(checkInOffset: 5, checkOutOffset: 8, from: now)
        let reminders = StayReminder.reminders(for: [s], viewerID: guest, now: now)

        #expect(reminders.first { $0.kind == .checkIn }?.identifier == "stay-checkIn-stay-1")
        #expect(reminders.first { $0.kind == .checkOut }?.identifier == "stay-checkOut-stay-1")
        // Distinct identifiers so scheduling one never clobbers the other.
        #expect(Set(reminders.map(\.identifier)).count == reminders.count)
    }
}

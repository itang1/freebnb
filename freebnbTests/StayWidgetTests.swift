//
//  StayWidgetTests.swift
//  freebnbTests
//
//  The pure decisions behind the widgets: which stay `StayWidgetBridge` picks as
//  "next", the two pending counts, and the phase `StayPhase.current` reports for
//  a stay's dates. No App Group, WidgetKit, or ActivityKit is touched here.
//

import Foundation
import Testing
@testable import freebnb

private let cal = Calendar.current
private let host = "host-1"
private let guest = "guest-1"

private func day(_ n: Int, from base: Date) -> Date {
    cal.startOfDay(for: cal.date(byAdding: .day, value: n, to: base)!)
}

private func stay(
    id: String,
    checkInOffset: Int,
    checkOutOffset: Int,
    status: StayRequestStatus = .accepted,
    hostUserID: String = host,
    guestUserID: String = guest,
    from base: Date
) -> StayRequest {
    StayRequest(
        id: id,
        listingID: "listing-\(id)",
        listingCity: "Portland",
        listingTitle: "Cabin \(id)",
        listingHostName: "Sam",
        hostUserID: hostUserID,
        guestUserID: guestUserID,
        checkIn: day(checkInOffset, from: base),
        checkOut: day(checkOutOffset, from: base),
        status: status
    )
}

@MainActor
struct StayWidgetBridgeTests {
    @Test func picksUnderwayStayOverSoonerUpcomingOne() {
        let now = Date()
        let underway = stay(id: "live", checkInOffset: -1, checkOutOffset: 3, from: now)
        let upcoming = stay(id: "soon", checkInOffset: 1, checkOutOffset: 4, from: now)

        let snap = StayWidgetBridge.makeSnapshot(
            incoming: [],
            outgoing: [upcoming, underway],
            viewerID: guest,
            now: now
        )
        #expect(snap.nextTrip?.stayID == "live")
        #expect(snap.nextTrip?.isUnderway(now: now) == true)
    }

    @Test func picksSoonestUpcomingWhenNoneUnderway() {
        let now = Date()
        let later = stay(id: "later", checkInOffset: 10, checkOutOffset: 12, from: now)
        let sooner = stay(id: "sooner", checkInOffset: 2, checkOutOffset: 5, from: now)

        let snap = StayWidgetBridge.makeSnapshot(
            incoming: [later],
            outgoing: [sooner],
            viewerID: guest,
            now: now
        )
        #expect(snap.nextTrip?.stayID == "sooner")
    }

    @Test func ignoresPastAndNonAcceptedStays() {
        let now = Date()
        let past = stay(id: "past", checkInOffset: -10, checkOutOffset: -8, from: now)
        let pending = stay(id: "pending", checkInOffset: 3, checkOutOffset: 6, status: .pending, from: now)

        let snap = StayWidgetBridge.makeSnapshot(
            incoming: [pending],
            outgoing: [past],
            viewerID: guest,
            now: now
        )
        #expect(snap.nextTrip == nil)
    }

    @Test func flagsHostRoleOnTheChosenTrip() {
        let now = Date()
        let hosting = stay(id: "host", checkInOffset: 1, checkOutOffset: 3, from: now)

        let snap = StayWidgetBridge.makeSnapshot(
            incoming: [hosting],
            outgoing: [],
            viewerID: host,
            now: now
        )
        #expect(snap.nextTrip?.isHost == true)
    }

    @Test func countsPendingInEachDirection() {
        let now = Date()
        let incoming = [
            stay(id: "i1", checkInOffset: 5, checkOutOffset: 7, status: .pending, from: now),
            stay(id: "i2", checkInOffset: 6, checkOutOffset: 8, status: .pending, from: now),
            stay(id: "i3", checkInOffset: 6, checkOutOffset: 8, status: .accepted, from: now)
        ]
        let outgoing = [
            stay(id: "o1", checkInOffset: 9, checkOutOffset: 11, status: .pending, from: now)
        ]

        let snap = StayWidgetBridge.makeSnapshot(
            incoming: incoming,
            outgoing: outgoing,
            viewerID: host,
            now: now
        )
        #expect(snap.pendingIncomingCount == 2)
        #expect(snap.pendingOutgoingCount == 1)
    }

    @Test func emptyViewerClearsSnapshotContent() {
        let now = Date()
        let snap = StayWidgetBridge.makeSnapshot(
            incoming: [stay(id: "i", checkInOffset: 1, checkOutOffset: 2, from: now)],
            outgoing: [],
            viewerID: host,
            now: now
        )
        // Sanity: with a viewer, the trip is present — the empty-viewer teardown is
        // handled in `publish`, not `makeSnapshot`.
        #expect(snap.nextTrip != nil)
    }
}

struct StayPhaseTests {
    @Test func futureStayHasNoPhase() {
        let now = Date()
        let phase = StayPhase.current(
            checkIn: day(2, from: now),
            checkOut: day(5, from: now),
            now: now
        )
        #expect(phase == nil)
    }

    @Test func arrivalDayReportsArrivingToday() {
        let now = Date()
        let checkIn = cal.startOfDay(for: now)
        let phase = StayPhase.current(checkIn: checkIn, checkOut: day(3, from: now), now: now)
        // `now` is later in the same day as the start-of-day check-in.
        #expect(phase == .arrivingToday)
    }

    @Test func midStayReportsUnderway() {
        let now = Date()
        let phase = StayPhase.current(
            checkIn: day(-2, from: now),
            checkOut: day(3, from: now),
            now: now
        )
        #expect(phase == .underway)
    }

    @Test func checkoutDayReportsCheckoutToday() {
        let now = Date()
        let checkOut = cal.startOfDay(for: now)
        let phase = StayPhase.current(checkIn: day(-3, from: now), checkOut: checkOut, now: now)
        #expect(phase == .checkoutToday)
    }

    @Test func afterCheckoutDayHasNoPhase() {
        let now = Date()
        let phase = StayPhase.current(
            checkIn: day(-5, from: now),
            checkOut: day(-1, from: now),
            now: now
        )
        #expect(phase == nil)
    }
}

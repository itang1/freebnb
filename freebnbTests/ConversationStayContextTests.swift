//
//  ConversationStayContextTests.swift
//  freebnbTests
//
//  The chip on a conversation row: which stay it picks, and — more importantly —
//  when it stays quiet. A chip that lingers after a trip ends turns into
//  furniture, so most of these pin the absence.
//

import Foundation
import Testing
@testable import freebnb

private let me = "me"
private let them = "them"
private let stranger = "stranger"

private func day(_ offset: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
}

private func stay(
    status: StayRequestStatus,
    hostUserID: String = them,
    guestUserID: String = me,
    checkIn: Date = day(5),
    checkOut: Date = day(8)
) -> StayRequest {
    StayRequest(
        listingID: "listing-1",
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: hostUserID,
        guestUserID: guestUserID,
        checkIn: checkIn,
        checkOut: checkOut,
        status: status
    )
}

private func context(_ stays: [StayRequest]) -> ConversationStayContext? {
    ConversationStay.context(between: me, and: them, stays: stays)
}

struct ConversationStayContextTests {
    @Test func anAcceptedFutureStayReadsAsConfirmed() {
        let result = context([stay(status: .accepted)])
        #expect(result?.kind == .upcoming)
        #expect(result?.isActionable == false)
    }

    @Test func aStayInProgressReadsAsUnderway() {
        let result = context([stay(status: .accepted, checkIn: day(-1), checkOut: day(2))])
        #expect(result?.kind == .underway)
    }

    /// The distinction the chip exists for: a request *I* owe an answer on is
    /// something to act on, and one I'm waiting to hear back about is not.
    @Test func itSaysWhichSideOwesTheAnswer() {
        // They asked to stay at my place, so it waits on me.
        let incoming = context([stay(status: .pending, hostUserID: me, guestUserID: them)])
        #expect(incoming?.kind == .awaitingYou)
        #expect(incoming?.isActionable == true)

        // I asked to stay at theirs, so it waits on them.
        let outgoing = context([stay(status: .pending)])
        #expect(outgoing?.kind == .awaitingThem)
        #expect(outgoing?.isActionable == false)
    }

    @Test func anOfferTheyMadeMeWaitsOnMe() {
        let result = context([stay(status: .offered)])
        #expect(result?.kind == .awaitingYou)
    }

    /// A plain friend chat is the common case and must stay unadorned.
    @Test func aConversationWithNoStayGetsNoChip() {
        #expect(context([]) == nil)
    }

    @Test func settledStaysNeverShow() {
        for status in [StayRequestStatus.declined, .cancelled, .completed] {
            #expect(context([stay(status: status)]) == nil, "\(status) should not caption a thread")
        }
    }

    /// An accepted stay stays `accepted` in Firestore until the nightly sweep
    /// completes it, so the chip has to notice checkout itself. Otherwise a
    /// thread claims a trip is confirmed for hours after the guest went home.
    @Test func anAcceptedStayStopsShowingOnceCheckoutHasPassed() {
        #expect(context([stay(status: .accepted, checkIn: day(-5), checkOut: day(-2))]) == nil)
    }

    /// Stays with other people share the store; only this thread's belong here.
    @Test func aStayWithSomebodyElseNeverLeaksIn() {
        let elsewhere = stay(status: .accepted, hostUserID: stranger, guestUserID: me)
        #expect(context([elsewhere]) == nil)
    }

    /// When several are live at once the most urgent wins, so the row never
    /// shows "confirmed" while a request sits unanswered underneath it.
    @Test func theMostUrgentStayWins() {
        let stays = [
            stay(status: .accepted),
            stay(status: .pending, hostUserID: me, guestUserID: them)
        ]
        #expect(context(stays)?.kind == .awaitingYou)

        // Underway outranks a merely upcoming one.
        let both = [
            stay(status: .accepted, checkIn: day(10), checkOut: day(12)),
            stay(status: .accepted, checkIn: day(-1), checkOut: day(2))
        ]
        #expect(context(both)?.kind == .underway)
    }

    @Test func aSignedOutViewerGetsNoChip() {
        #expect(ConversationStay.context(between: "", and: them, stays: [stay(status: .accepted)]) == nil)
    }
}

// MARK: - Check-in kit banner timing

struct CheckInKitBannerTimingTests {
    private func kit(checkIn: Date, checkOut: Date) -> CheckInKit {
        CheckInKit(
            stayID: "s1",
            listingID: "l1",
            listingTitle: "Place",
            city: "Town",
            state: "CA",
            hostName: "Host",
            checkIn: checkIn,
            checkOut: checkOut,
            street: "1 Main St",
            savedAt: Date()
        )
    }

    /// The banner is for arrival, so it appears the day before check-in and goes
    /// away at checkout. Showing it earlier clutters a thread that is still about
    /// whether the dates work; showing it later leaves someone's address pinned
    /// above a conversation for no reason.
    @Test func theBannerOnlyAppearsAroundTheStay() {
        let arriving = kit(checkIn: day(1), checkOut: day(4))
        #expect(CheckInKitBanner.isRelevant(arriving))

        let underway = kit(checkIn: day(-1), checkOut: day(2))
        #expect(CheckInKitBanner.isRelevant(underway))

        let farOff = kit(checkIn: day(10), checkOut: day(13))
        #expect(!CheckInKitBanner.isRelevant(farOff))

        let over = kit(checkIn: day(-6), checkOut: day(-3))
        #expect(!CheckInKitBanner.isRelevant(over))
    }
}

//
//  CirclePolicyTests.swift
//  freebnbTests
//
//  The pure half of Circles: how a policy resolves, and what it withholds from
//  the guest's calendar.
//
//  These decisions are duplicated in `firestore.rules`, which is the half that
//  actually enforces them (rules-tests/circles.test.mjs). The two have to agree,
//  because a client that hides more than the rules refuse annoys a guest, and a
//  client that hides less shows them an option that fails — and a failure is the
//  one thing a restricted friend must never see.
//

import Foundation
import Testing
@testable import freebnb

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    guard let date = utc.date(from: components) else {
        fatalError("could not build \(year)-\(month)-\(day) \(hour):00")
    }
    return date
}

private let allArrivals = ArrivalWindow.allCases.map(\.rawValue)

private func circle(_ id: String, _ policy: BookingPolicy, isDefault: Bool = false) -> FriendCircle {
    FriendCircle(id: id, name: id, isDefault: isDefault, policy: policy)
}

// MARK: - Resolution

@Suite("Circle policy resolution")
struct CirclePolicyResolutionTests {
    private let strict = BookingPolicy(allowedArrivalOptions: ["morning"], minNoticeHours: 72)
    private let loose = BookingPolicy(allowedArrivalOptions: allArrivals, minNoticeHours: 0)

    @Test("a per-friend override beats the circle it is set on")
    func overrideWins() {
        let (policy, source) = CirclePolicyResolver.resolve(
            membership: CircleMembership(id: "f", circleID: "c1", overridePolicy: loose),
            circles: [circle("default", strict, isDefault: true), circle("c1", strict)]
        )
        #expect(policy == loose)
        #expect(source == .override)
    }

    @Test("a membership with no override takes its circle's policy")
    func circleWins() {
        let (policy, source) = CirclePolicyResolver.resolve(
            membership: CircleMembership(id: "f", circleID: "c1"),
            circles: [circle("default", loose, isDefault: true), circle("c1", strict)]
        )
        #expect(policy == strict)
        #expect(source == .circle(id: "c1", name: "c1"))
    }

    // The window between a friend request being accepted and the host's client
    // filing them. Default is a real policy-bearing circle, so it answers.
    @Test("a friend with no membership document is governed by Default")
    func noMembershipFallsBackToDefault() {
        let (policy, source) = CirclePolicyResolver.resolve(
            membership: nil,
            circles: [circle("default", strict, isDefault: true), circle("c1", loose)]
        )
        #expect(policy == strict)
        #expect(source == .fallbackDefault)
    }

    @Test("a membership naming a deleted circle falls back to Default")
    func deletedCircleFallsBackToDefault() {
        let (policy, source) = CirclePolicyResolver.resolve(
            membership: CircleMembership(id: "f", circleID: "gone"),
            circles: [circle("default", strict, isDefault: true)]
        )
        #expect(policy == strict)
        #expect(source == .fallbackDefault)
    }

    // A host who has not opened the app since Circles shipped. Not a special
    // case for Default — Default does not exist yet — and the behaviour is
    // exactly what they had before the feature.
    @Test("a host with no circles at all restricts nothing")
    func noCirclesIsUnrestricted() {
        let (policy, source) = CirclePolicyResolver.resolve(membership: nil, circles: [])
        #expect(policy == .permissive)
        #expect(source == .unconfigured)
        #expect(ArrivalWindow.allCases.allSatisfy(policy.allows))
    }

    // Default's permissiveness is a stored value the host may edit, not a branch
    // in the code. Restricting it has to bite exactly as hard as restricting any
    // other circle.
    @Test("a restricted Default circle restricts")
    func defaultIsNotSpeciallyPermissive() {
        let (policy, _) = CirclePolicyResolver.resolve(
            membership: CircleMembership(id: "f", circleID: "default"),
            circles: [circle("default", strict, isDefault: true)]
        )
        #expect(!policy.allows(.lateNight))
        #expect(policy.minNoticeHours == 72)
    }
}

// MARK: - Arrival options

@Suite("Allowed arrival options")
struct ArrivalOptionTests {
    @Test("allowed windows come back in the enum's order, not the stored order")
    func stableOrder() {
        let policy = BookingPolicy(allowedArrivalOptions: ["evening", "morning"])
        #expect(policy.allowedArrivalWindows == [.morning, .evening])
    }

    @Test("a raw value this build doesn't know is dropped rather than crashing")
    func unknownRawValueIgnored() {
        let policy = BookingPolicy(allowedArrivalOptions: ["morning", "dawn"])
        #expect(policy.allowedArrivalWindows == [.morning])
    }

    @Test("a policy with no options left is not valid")
    func emptyIsInvalid() {
        #expect(!BookingPolicy(allowedArrivalOptions: []).isValid)
    }

    @Test("minNoticeHours past a year is not valid")
    func noticeBoundedAtAYear() {
        #expect(BookingPolicy(minNoticeHours: BookingPolicy.maxNoticeHours).isValid)
        #expect(!BookingPolicy(minNoticeHours: BookingPolicy.maxNoticeHours + 1).isValid)
    }
}

// MARK: - Minimum notice

@Suite("Minimum notice")
struct MinimumNoticeTests {
    // checkIn is a local start-of-day, so the horizon has to round *up* to a
    // whole day: a 12-hour notice at 9pm rules out tomorrow, because tomorrow
    // starts in three hours. Rounding down would offer a day the rules refuse.
    @Test("the horizon rounds up to the next whole day")
    func roundsUpToWholeDay() {
        let policy = BookingPolicy(minNoticeHours: 12)
        let earliest = policy.earliestCheckIn(now: at(2026, 3, 10, 21), calendar: utc)
        #expect(earliest == at(2026, 3, 12))
    }

    @Test("a horizon landing exactly on midnight keeps that day")
    func exactMidnightIsKept() {
        let policy = BookingPolicy(minNoticeHours: 24)
        let earliest = policy.earliestCheckIn(now: at(2026, 3, 10), calendar: utc)
        #expect(earliest == at(2026, 3, 11))
    }

    @Test("no minimum leaves today bookable")
    func zeroNoticeKeepsToday() {
        let policy = BookingPolicy(minNoticeHours: 0)
        #expect(policy.earliestCheckIn(now: at(2026, 3, 10, 14), calendar: utc) == at(2026, 3, 10))
    }
}

// MARK: - What the guest's calendar loses

@Suite("Days a policy withholds")
struct DaysWithheldTests {
    private func withheld(_ policy: BookingPolicy, used: Int = 0, windowEndsAt: Date? = nil) -> Set<Date> {
        BookingPolicyGuestView.daysWithheld(
            by: policy,
            staysUsedInWindow: used,
            windowEndsAt: windowEndsAt,
            from: at(2026, 3, 10, 9),
            monthsAhead: 12,
            calendar: utc
        )
    }

    @Test("a permissive policy withholds nothing")
    func permissiveWithholdsNothing() {
        #expect(withheld(.permissive).isEmpty)
    }

    // 72 hours from 9am on the 10th lands at 9am on the 13th, and the 13th
    // *starts* before that — so the first day a guest can actually check in on
    // is the 14th. Rounding the other way would offer a day the rules refuse.
    @Test("notice withholds every day before the horizon, and none after")
    func noticeWithholdsThePrefix() {
        let days = withheld(BookingPolicy(minNoticeHours: 72))
        #expect(days.contains(at(2026, 3, 10)))
        #expect(days.contains(at(2026, 3, 13)))
        #expect(!days.contains(at(2026, 3, 14)))
    }

    // The whole calendar, not a marked subset: a spent window has to read as
    // "the host has nothing free", which is a sentence about the host.
    @Test("a spent frequency window closes the calendar until it reopens")
    func spentWindowClosesEverything() {
        let policy = BookingPolicy(maxStaysPerPeriod: StayFrequencyCap(count: 2, periodDays: 30))
        let days = withheld(policy, used: 2, windowEndsAt: at(2026, 4, 1))
        #expect(days.contains(at(2026, 3, 10)))
        #expect(days.contains(at(2026, 3, 31)))
        #expect(!days.contains(at(2026, 4, 1)))
    }

    @Test("a window with slots left withholds nothing")
    func unspentWindowWithholdsNothing() {
        let policy = BookingPolicy(maxStaysPerPeriod: StayFrequencyCap(count: 2, periodDays: 30))
        #expect(withheld(policy, used: 1, windowEndsAt: at(2026, 4, 1)).isEmpty)
    }

    // A ten-year cap must not build ten years of dates for a grid that shows
    // twelve months.
    @Test("the withheld set is clamped to the grid's own horizon")
    func clampedToGridHorizon() {
        let policy = BookingPolicy(maxStaysPerPeriod: StayFrequencyCap(count: 1, periodDays: 3650))
        let days = withheld(policy, used: 1, windowEndsAt: at(2036, 1, 1))
        #expect(days.count < 500)
        #expect(!days.contains(at(2027, 6, 1)))
    }
}

// MARK: - The frequency counter

@Suite("Stay frequency counter")
struct StayCounterTests {
    private let cap = StayFrequencyCap(count: 2, periodDays: 30)

    private func counter(start: Date, count: Int) -> StayCounter {
        StayCounter(hostUserID: "h", guestUserID: "g", windowStart: start, count: count)
    }

    @Test("the document id names the pair, host first")
    func documentIDNamesThePair() {
        #expect(StayCounter.documentID(hostUserID: "h", guestUserID: "g") == "h_g")
    }

    @Test("an elapsed window has spent nothing")
    func elapsedWindowIsSpentZero() {
        let old = counter(start: at(2026, 1, 1), count: 2)
        #expect(old.spent(cap: cap, now: at(2026, 3, 10), calendar: utc) == 0)
    }

    @Test("an open window reports what it has spent")
    func openWindowReportsCount() {
        let open = counter(start: at(2026, 3, 1), count: 1)
        #expect(open.spent(cap: cap, now: at(2026, 3, 10), calendar: utc) == 1)
    }

    // The two shapes the rules accept, and nothing else: increment inside the
    // window, or open a new one once it has elapsed. windowStart is pinned in
    // between, which is what stops the window being slid forward to dodge the cap.
    @Test("advancing inside the window increments and keeps windowStart")
    func advanceIncrements() {
        let open = counter(start: at(2026, 3, 1), count: 1)
        let next = open.advanced(cap: cap, now: at(2026, 3, 10), calendar: utc)
        #expect(next.count == 2)
        #expect(next.windowStart == at(2026, 3, 1))
    }

    @Test("advancing after the window has elapsed opens a fresh one")
    func advanceReopens() {
        let old = counter(start: at(2026, 1, 1), count: 2)
        let next = old.advanced(cap: cap, now: at(2026, 3, 10), calendar: utc)
        #expect(next.count == 1)
        #expect(next.windowStart == at(2026, 3, 10))
    }
}

// MARK: - The guest-side store

@Suite("Booking policy store")
@MainActor
struct BookingPolicyStoreTests {
    private func store(policy: BookingPolicy?, counter: StayCounter? = nil) -> BookingPolicyStore {
        let repository = InMemoryCircleRepository()
        if let policy {
            repository.publishedByHost["h"] = ["g": policy]
        }
        if let counter {
            repository.counters[StayCounter.documentID(hostUserID: "h", guestUserID: "g")] = counter
        }
        return BookingPolicyStore(repository: repository)
    }

    // The safe direction for a *display* decision: the sheet offers what it
    // cannot rule out, and the rules are what refuse. Erring the other way would
    // grey out a calendar because a read failed.
    @Test("a host who has published nothing comes back unrestricted")
    func noProjectionIsUnrestricted() async {
        let resolved = await store(policy: nil).resolve(hostID: "h", guestID: "g")
        #expect(resolved.policy == .permissive)
        #expect(resolved.staysUsedInWindow == 0)
    }

    @Test("an uncapped policy needs no counter to send")
    func uncappedNeedsNoCounter() async {
        let store = store(policy: BookingPolicy(minNoticeHours: 24))
        let resolved = await store.resolve(hostID: "h", guestID: "g")
        #expect(store.advancedCounter(for: resolved, hostID: "h", guestID: "g") == nil)
    }

    @Test("a capped policy with no counter yet opens one")
    func cappedOpensACounter() async {
        let policy = BookingPolicy(maxStaysPerPeriod: StayFrequencyCap(count: 2, periodDays: 30))
        let store = store(policy: policy)
        let resolved = await store.resolve(hostID: "h", guestID: "g")
        let advanced = store.advancedCounter(for: resolved, hostID: "h", guestID: "g", now: at(2026, 3, 10))
        #expect(advanced?.count == 1)
        #expect(advanced?.windowStart == at(2026, 3, 10))
    }

    @Test("a capped policy folds the open window's spend into what it resolves")
    func cappedReadsTheCounter() async {
        let policy = BookingPolicy(maxStaysPerPeriod: StayFrequencyCap(count: 2, periodDays: 30))
        let store = store(
            policy: policy,
            counter: StayCounter(hostUserID: "h", guestUserID: "g", windowStart: Date(), count: 2)
        )
        let resolved = await store.resolve(hostID: "h", guestID: "g")
        #expect(resolved.staysUsedInWindow == 2)
        #expect(resolved.windowEndsAt != nil)
    }
}

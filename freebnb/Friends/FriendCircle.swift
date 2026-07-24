//
//  FriendCircle.swift
//  freebnb
//
//  Circles: the host's own grouping of their friends, and the booking rules
//  that hang off each group. See docs/internal/CIRCLES.md for the design.
//
//  Everything in this file is pure. The resolution order (`ResolvedPolicy`), the
//  arithmetic that turns a policy into greyed-out days, and the seeding of a new
//  host's circles are all decisions that have to agree exactly with
//  `firestore.rules`, so they live apart from the store and the views and are
//  unit-tested directly (freebnbTests/CirclePolicyTests.swift).
//
//  A guest never reads any of these documents. What reaches their device is the
//  resolved `BookingPolicy` alone, projected into
//  `users/{hostID}/bookingPolicies/{guestID}` — no circle id, no circle name.
//

import FirebaseFirestore
import Foundation

// MARK: - Policy

/// How often one person may book. Absent (`nil` on the policy) means uncapped;
/// there is no sentinel count standing in for "unlimited", because a host who
/// clears the cap should leave no number behind to misread later.
struct StayFrequencyCap: Codable, Hashable, Sendable {
    var count: Int
    var periodDays: Int

    /// The bounds the rules enforce. Mirrored in `firestore.rules`
    /// (isValidPolicy) and in rules-tests/circles.test.mjs.
    static let countRange = 1...100
    static let periodRange = 1...3650

    var isValid: Bool {
        Self.countRange.contains(count) && Self.periodRange.contains(periodDays)
    }

    /// "2 stays every 30 days", the one line the host's circle row shows.
    var summary: String {
        "\(count) stay\(count == 1 ? "" : "s") every \(periodDays) day\(periodDays == 1 ? "" : "s")"
    }
}

/// The rules a circle (or a single friend, via an override) applies to a
/// booking. Every field is host-configurable on every circle, Default included:
/// nothing here is switched on by which circle it belongs to.
struct BookingPolicy: Codable, Hashable, Sendable {
    /// Which of the five arrival times this friend may pick in the request
    /// sheet. Stored as `ArrivalWindow` raw values so the wire format matches
    /// the whitelist `firestore.rules` already applies to `arrivalWindow`.
    var allowedArrivalOptions: [String]

    /// Minimum lead time before check-in. 0 means no minimum.
    var minNoticeHours: Int

    /// Frequency throttle, or nil for uncapped.
    var maxStaysPerPeriod: StayFrequencyCap?

    /// The upper bound the rules enforce on `minNoticeHours`: a year. Past that
    /// the field stops meaning "give me notice" and starts meaning "never", and
    /// a host who wants never has a delete button.
    static let maxNoticeHours = 8760

    init(
        allowedArrivalOptions: [String] = ArrivalWindow.allCases.map(\.rawValue),
        minNoticeHours: Int = 0,
        maxStaysPerPeriod: StayFrequencyCap? = nil
    ) {
        self.allowedArrivalOptions = allowedArrivalOptions
        self.minNoticeHours = minNoticeHours
        self.maxStaysPerPeriod = maxStaysPerPeriod
    }

    /// What a brand-new circle starts as, Default included: everything allowed.
    /// This is a *starting point a host may edit*, not an "unrestricted" state
    /// the code branches on — no reader of a policy ever asks whether it equals
    /// this one.
    static let permissive = BookingPolicy()

    /// The arrival options as the typed enum, in the enum's own order so the
    /// picker never reorders itself to match however the array was stored.
    /// Unknown raw values (a policy written by a newer client) are dropped.
    var allowedArrivalWindows: [ArrivalWindow] {
        let allowed = Set(allowedArrivalOptions)
        return ArrivalWindow.allCases.filter { allowed.contains($0.rawValue) }
    }

    func allows(_ window: ArrivalWindow) -> Bool {
        allowedArrivalOptions.contains(window.rawValue)
    }

    /// A policy the host could not have authored is not a policy to enforce.
    /// The rules validate the same shape on write; this is the client's half,
    /// used to keep the editor's Save button honest.
    var isValid: Bool {
        !allowedArrivalOptions.isEmpty
            && Set(allowedArrivalOptions).isSubset(of: Set(ArrivalWindow.allCases.map(\.rawValue)))
            && (0...Self.maxNoticeHours).contains(minNoticeHours)
            && (maxStaysPerPeriod?.isValid ?? true)
    }

    /// Whether this policy restricts anything at all. Host-facing only — it
    /// drives the "No restrictions" subtitle on a circle row, and nothing about
    /// enforcement branches on it.
    var isPermissive: Bool {
        allowedArrivalWindows.count == ArrivalWindow.allCases.count
            && minNoticeHours == 0
            && maxStaysPerPeriod == nil
    }

    /// The earliest check-in day this policy permits, as a start-of-day.
    ///
    /// `checkIn` is always a local start-of-day (that is what the grid selects
    /// and what the request stores), so the comparison has to be made against
    /// one too, and the *same* one the rules will compute from `request.time`.
    /// Rounding up to the next whole day is what keeps the two in step: a
    /// 12-hour notice at 9pm rules out tomorrow, because tomorrow starts in
    /// three hours.
    ///
    /// No minimum returns today, and does not go through that arithmetic at all.
    /// It cannot: today's start-of-day is already behind `now`, so rounding up
    /// would push a zero-hour notice to tomorrow and quietly withdraw the
    /// same-day request the app has always allowed. `firestore.rules` skips the
    /// bound for zero for exactly the same reason.
    func earliestCheckIn(now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard minNoticeHours > 0 else { return calendar.startOfDay(for: now) }
        let horizon = now.addingTimeInterval(TimeInterval(minNoticeHours) * 3600)
        let startOfHorizonDay = calendar.startOfDay(for: horizon)
        guard startOfHorizonDay < horizon else { return startOfHorizonDay }
        return calendar.date(byAdding: .day, value: 1, to: startOfHorizonDay) ?? horizon
    }
}

// MARK: - FriendCircle

/// A host-managed group of friends. Not an enum: the host names these, and the
/// only fixed one is Default, which is fixed by its document id rather than by
/// its name or by a type.
struct FriendCircle: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried alongside the decoded document rather than in
    /// it. Not `@DocumentID`, because these are constructed locally too — the
    /// seeded starter circles know their ids before any document exists — and
    /// that wrapper logs a warning and discards the value every time one is.
    /// The repository stamps it from `documentID` on the way in.
    var id: String?
    var name: String
    /// True only on the circle at document id `FriendCircle.defaultID`. Carried on the
    /// document so a list of circles sorts and renders without re-deriving it
    /// from the id, and pinned by the rules so it cannot be claimed elsewhere.
    var isDefault: Bool
    var sortOrder: Int
    var policy: BookingPolicy
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it is never encoded into the document.
    enum CodingKeys: String, CodingKey {
        case name, isDefault, sortOrder, policy, createdAt, updatedAt
    }

    /// The Default circle's document id, and the whole reason "every friend
    /// resolves to a policy" is a property of the path rather than of a query.
    /// Security rules cannot ask which circle has `isDefault == true`; they can
    /// always `get()` this one.
    static let defaultID = "default"

    static let nameLimit = 40

    init(
        id: String? = nil,
        name: String,
        isDefault: Bool = false,
        sortOrder: Int = 0,
        policy: BookingPolicy = .permissive,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.policy = policy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Default cannot be deleted: a new friend always needs somewhere to land,
    /// and every resolution ends here. Everything else about it — its name, its
    /// whole policy — is the host's to change.
    var isDeletable: Bool { !isDefault }

    /// The circles a host starts with. Default plus two ordinary ones, all three
    /// permissive: seeding a restriction the host never chose would be a decline
    /// they never made. Renaming or deleting the latter two is expected.
    static func seeded() -> [FriendCircle] {
        [
            FriendCircle(id: defaultID, name: "Everyone else", isDefault: true, sortOrder: 0),
            FriendCircle(id: "closeFriend", name: "Close friend", sortOrder: 1),
            FriendCircle(id: "acquaintance", name: "Acquaintance", sortOrder: 2)
        ]
    }
}

// MARK: - Membership

/// Which circle a host has filed one friend under, plus the optional policy the
/// host set on that person directly. One document per friend, keyed by their
/// uid so `firestore.rules` can reach it in a single `get()`.
struct CircleMembership: Identifiable, Codable, Hashable, Sendable {
    /// The friend's user id, which is this document's id. Carried beside the
    /// document rather than in it, for the same reason as `FriendCircle.id`.
    var id: String?
    var circleID: String
    /// A policy set on this one person, superseding their circle's. Absent for
    /// the overwhelming majority of friends.
    var overridePolicy: BookingPolicy?
    @ServerTimestamp var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case circleID, overridePolicy, updatedAt
    }

    init(id: String? = nil, circleID: String = FriendCircle.defaultID, overridePolicy: BookingPolicy? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.circleID = circleID
        self.overridePolicy = overridePolicy
        self.updatedAt = updatedAt
    }
}

// MARK: - Resolution

enum CirclePolicyResolver {
    /// Where a resolved policy came from. Host-facing only: it is what lets the
    /// friend row say "Close friend · custom rules" instead of making the host
    /// open the sheet to find out. It is never projected to a guest.
    enum Source: Equatable {
        case override
        case circle(id: String, name: String)
        /// No membership document yet, or one naming a circle that has since
        /// been deleted. The Default circle answers, which is what it is for.
        case fallbackDefault
        /// The host has no circles at all — a host who has not opened the app
        /// since Circles shipped and whose migration has not run. Nothing is
        /// restricted, which is exactly the behaviour they had before.
        case unconfigured
    }

    /// The policy governing `friendID` booking with the host who owns `circles`
    /// and `membership`.
    ///
    /// Precedence, and it always terminates: per-friend override, then the
    /// circle the membership names, then the Default circle. `firestore.rules`
    /// walks the identical chain against the identical documents — if you change
    /// the order here, change it there.
    static func resolve(
        membership: CircleMembership?,
        circles: [FriendCircle]
    ) -> (policy: BookingPolicy, source: Source) {
        if let override = membership?.overridePolicy {
            return (override, .override)
        }
        if let circleID = membership?.circleID,
           let circle = circles.first(where: { $0.id == circleID }) {
            return (circle.policy, .circle(id: circleID, name: circle.name))
        }
        if let fallback = circles.first(where: { $0.id == FriendCircle.defaultID }) {
            return (fallback.policy, .fallbackDefault)
        }
        return (.permissive, .unconfigured)
    }
}

// MARK: - Guest-side derivation

/// Turns a resolved policy into the two things the guest's request sheet needs:
/// which arrival options to offer, and which days to grey out.
///
/// Both answers are deliberately shaped to be indistinguishable from the
/// ordinary ones. A day withheld by a notice rule joins the same
/// `unavailableDays` set that the host's blocked days and other people's
/// bookings go into, and the grid draws it the way it draws any other closed
/// day — no reason, no styling of its own, nothing to compare against.
enum BookingPolicyGuestView {
    /// Every day from the start of the visible calendar up to (but not
    /// including) the earliest the policy permits.
    ///
    /// Returns days rather than a range so the caller can union it straight into
    /// the set the grid already consumes.
    static func daysWithheld(
        by policy: BookingPolicy,
        staysUsedInWindow: Int,
        windowEndsAt: Date?,
        from: Date = Date(),
        monthsAhead: Int,
        calendar: Calendar = .current
    ) -> Set<Date> {
        // A spent frequency window closes the whole calendar until it rolls.
        // Every day the guest could otherwise reach, not a marked subset: the
        // point is that this reads as "the host has nothing free", which is a
        // sentence about the host and not about the guest.
        if let cap = policy.maxStaysPerPeriod, staysUsedInWindow >= cap.count {
            let reopens = windowEndsAt ?? calendar.date(byAdding: .day, value: cap.periodDays, to: from) ?? from
            return days(from: from, until: max(reopens, from), monthsAhead: monthsAhead, calendar: calendar)
        }
        let earliest = policy.earliestCheckIn(now: from, calendar: calendar)
        return days(from: from, until: earliest, monthsAhead: monthsAhead, calendar: calendar)
    }

    /// Start-of-days in `[from, until)`, clamped to the window the grid can
    /// actually show so a hundred-year cap doesn't build a hundred years of
    /// dates.
    private static func days(
        from: Date,
        until: Date,
        monthsAhead: Int,
        calendar: Calendar = .current
    ) -> Set<Date> {
        let start = calendar.startOfDay(for: from)
        let horizon = calendar.date(byAdding: .month, value: monthsAhead + 1, to: start) ?? start
        let end = min(calendar.startOfDay(for: until), horizon)
        guard end > start else { return [] }
        var result: Set<Date> = []
        var day = start
        while day < end {
            result.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

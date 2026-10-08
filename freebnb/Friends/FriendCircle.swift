//
//  FriendCircle.swift
//  freebnb
//
//  Circles: a host's grouping of their friends and the booking rules per group.
//  See docs/internal/CIRCLES.md.
//
//  Everything here is pure, since it must agree exactly with `firestore.rules`,
//  and is unit-tested in freebnbTests/CirclePolicyTests.swift. A guest never
//  reads these documents; only the resolved `BookingPolicy` reaches them, via
//  `users/{hostID}/bookingPolicies/{guestID}`, with no circle id or name.
//

import FirebaseFirestore
import Foundation

// MARK: - Policy

/// How often one person may book. Nil on the policy means uncapped; there is no
/// sentinel count for "unlimited".
struct StayFrequencyCap: Codable, Hashable, Sendable {
    var count: Int
    var periodDays: Int

    /// The bounds the rules enforce (`isValidPolicy`, rules-tests/circles.test.mjs).
    static let countRange = 1...100
    static let periodRange = 1...3650

    var isValid: Bool {
        Self.countRange.contains(count) && Self.periodRange.contains(periodDays)
    }

    /// "2 stays every 30 days", shown on the host's circle row.
    var summary: String {
        "\(count) stay\(count == 1 ? "" : "s") every \(periodDays) day\(periodDays == 1 ? "" : "s")"
    }
}

/// The rules a circle (or a single friend's override) applies to a booking.
/// Every field is host-configurable on every circle, Default included.
struct BookingPolicy: Codable, Hashable, Sendable {
    /// Which of the five arrival times this friend may pick, stored as
    /// `ArrivalWindow` raw values to match the rules' whitelist.
    var allowedArrivalOptions: [String]

    /// Minimum lead time before check-in. 0 means no minimum.
    var minNoticeHours: Int

    /// Frequency throttle, or nil for uncapped.
    var maxStaysPerPeriod: StayFrequencyCap?

    /// The upper bound the rules enforce on `minNoticeHours`: a year.
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

    /// What a new circle starts as: everything allowed. A starting point the host
    /// may edit, not an "unrestricted" state the code branches on.
    static let permissive = BookingPolicy()

    /// The arrival options as the typed enum, in the enum's order. Unknown raw
    /// values (from a newer client) are dropped.
    var allowedArrivalWindows: [ArrivalWindow] {
        let allowed = Set(allowedArrivalOptions)
        return ArrivalWindow.allCases.filter { allowed.contains($0.rawValue) }
    }

    func allows(_ window: ArrivalWindow) -> Bool {
        allowedArrivalOptions.contains(window.rawValue)
    }

    /// Whether the policy is one a host could have authored; mirrors the rules'
    /// validation to keep the editor's Save button honest.
    var isValid: Bool {
        !allowedArrivalOptions.isEmpty
            && Set(allowedArrivalOptions).isSubset(of: Set(ArrivalWindow.allCases.map(\.rawValue)))
            && (0...Self.maxNoticeHours).contains(minNoticeHours)
            && (maxStaysPerPeriod?.isValid ?? true)
    }

    /// Whether this policy restricts anything. Host-facing only (the "No restrictions" subtitle).
    var isPermissive: Bool {
        allowedArrivalWindows.count == ArrivalWindow.allCases.count
            && minNoticeHours == 0
            && maxStaysPerPeriod == nil
    }

    /// The earliest check-in day this policy permits, as a start-of-day.
    ///
    /// Rounds up to the next whole day to match what the rules compute from
    /// `request.time`: a 12-hour notice at 9pm rules out tomorrow. No minimum
    /// returns today without that arithmetic, which would push a zero-hour
    /// notice to tomorrow and withdraw same-day requests; the rules skip the
    /// bound for zero for the same reason.
    func earliestCheckIn(now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard minNoticeHours > 0 else { return calendar.startOfDay(for: now) }
        let horizon = now.addingTimeInterval(TimeInterval(minNoticeHours) * 3600)
        let startOfHorizonDay = calendar.startOfDay(for: horizon)
        guard startOfHorizonDay < horizon else { return startOfHorizonDay }
        return calendar.date(byAdding: .day, value: 1, to: startOfHorizonDay) ?? horizon
    }
}

// MARK: - FriendCircle

/// A host-managed group of friends. The only fixed one is Default, identified by its document id.
struct FriendCircle: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried beside the document. Not `@DocumentID`, which
    /// warns and discards the value for locally constructed circles. The repository stamps it.
    var id: String?
    var name: String
    /// True only on the circle at `FriendCircle.defaultID`; pinned by the rules so it can't be claimed elsewhere.
    var isDefault: Bool
    var sortOrder: Int
    var policy: BookingPolicy
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it isn't encoded.
    enum CodingKeys: String, CodingKey {
        case name, isDefault, sortOrder, policy, createdAt, updatedAt
    }

    /// The Default circle's document id. Rules can't query for `isDefault == true`,
    /// but they can always `get()` this one, so every friend resolves to a policy.
    static let defaultID = FirestorePaths.defaultCircleDocID

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

    /// Default can't be deleted: a new friend needs somewhere to land and every
    /// resolution ends here. Its name and policy are still the host's to change.
    var isDeletable: Bool { !isDefault }

    /// The circles a host starts with: Default plus two ordinary ones, all
    /// permissive so no restriction is seeded the host never chose.
    static func seeded() -> [FriendCircle] {
        [
            FriendCircle(id: defaultID, name: "Everyone else", isDefault: true, sortOrder: 0),
            FriendCircle(id: "closeFriend", name: "Close friend", sortOrder: 1),
            FriendCircle(id: "acquaintance", name: "Acquaintance", sortOrder: 2)
        ]
    }
}

// MARK: - Membership

/// Which circle a host filed one friend under, plus an optional per-person
/// policy. Keyed by the friend's uid so the rules reach it in one `get()`.
struct CircleMembership: Identifiable, Codable, Hashable, Sendable {
    /// The friend's user id (this document's id), carried beside the document like `FriendCircle.id`.
    var id: String?
    var circleID: String
    /// A policy set on this person, superseding their circle's. Rare.
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
    /// Where a resolved policy came from. Host-facing only, never projected to a guest.
    enum Source: Equatable {
        case override
        case circle(id: String, name: String)
        /// No membership document yet, or its circle was deleted; Default answers.
        case fallbackDefault
        /// The host has no circles (migration not run yet); nothing is restricted.
        case unconfigured
    }

    /// The policy governing `friendID` booking with the host who owns `circles`
    /// and `membership`. Precedence: per-friend override, then the named circle,
    /// then Default. `firestore.rules` walks the same chain; change both together.
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

/// Turns a resolved policy into what the guest's request sheet needs: arrival
/// options to offer and days to grey out. Withheld days join the same
/// `unavailableDays` set as blocked and booked days, with no reason or styling of their own.
enum BookingPolicyGuestView {
    /// Every day from the start of the visible calendar up to (not including) the
    /// earliest permitted, as days so callers can union them into the grid's set.
    static func daysWithheld(
        by policy: BookingPolicy,
        staysUsedInWindow: Int,
        windowEndsAt: Date?,
        from: Date = Date(),
        monthsAhead: Int,
        calendar: Calendar = .current
    ) -> Set<Date> {
        // A spent frequency window closes the whole calendar until it rolls, so it reads as "the host has
        // nothing free".
        if let cap = policy.maxStaysPerPeriod, staysUsedInWindow >= cap.count {
            let reopens = windowEndsAt ?? calendar.date(byAdding: .day, value: cap.periodDays, to: from) ?? from
            return days(from: from, until: max(reopens, from), monthsAhead: monthsAhead, calendar: calendar)
        }
        let earliest = policy.earliestCheckIn(now: from, calendar: calendar)
        return days(from: from, until: earliest, monthsAhead: monthsAhead, calendar: calendar)
    }

    /// Start-of-days in `[from, until)`, clamped to the window the grid can show.
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

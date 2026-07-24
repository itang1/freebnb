//
//  BookingPolicyStore.swift
//  freebnb
//
//  The guest's half of Circles, and deliberately a different type from
//  `CircleStore` rather than a second section of it. A host reads their circles,
//  their memberships, and everyone's overrides; a guest reads one document, the
//  policy a single host has resolved for them, and cannot reach anything else.
//  Two stores keeps that asymmetry something the compiler knows about instead of
//  something a comment asks you to remember.
//
//  Fetched on demand rather than listened to. A live listener would turn a host
//  tightening a policy into an event on the guest's screen — the calendar
//  quietly losing days while they look at it — and the one thing this feature
//  promises is that a restricted friend is never told. One read when the request
//  sheet opens, and the answer holds for as long as the sheet is up.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class BookingPolicyStore {
    /// What the request sheet needs to draw itself: the rules that apply, and
    /// how much of the frequency window the guest has already spent.
    struct Resolved: Equatable, Sendable {
        var policy: BookingPolicy
        /// Requests already made inside the open window. Zero when the window
        /// has elapsed or there is no cap.
        var staysUsedInWindow: Int
        /// When the open window ends, if a cap is in force and the window is
        /// still running.
        var windowEndsAt: Date?
        /// The counter as it stands, so the sheet can hand the advanced value to
        /// the write without re-reading it.
        var counter: StayCounter?

        /// Nothing configured: every option offered, no days withheld.
        static let unrestricted = Resolved(policy: .permissive, staysUsedInWindow: 0, windowEndsAt: nil, counter: nil)
    }

    @ObservationIgnored private let repository: CircleRepository
    @ObservationIgnored private let log = AppLog.logger("circles")

    init(repository: CircleRepository = FirestoreCircleRepository()) {
        self.repository = repository
    }

    /// The policy `hostID` has published for `guestID`, with the guest's own
    /// frequency counter folded in.
    ///
    /// A host who has published nothing, and a read that fails, both come back
    /// unrestricted. That is the safe direction for a *display* decision: the
    /// sheet offers what it cannot rule out, and `firestore.rules` is what
    /// actually refuses. Erring the other way would grey out a calendar because
    /// the network hiccuped.
    func resolve(hostID: String, guestID: String) async -> Resolved {
        guard !hostID.isEmpty, !guestID.isEmpty, hostID != guestID else { return .unrestricted }
        do {
            guard let policy = try await repository.fetchPolicy(hostID: hostID, guestID: guestID) else {
                return .unrestricted
            }
            guard let cap = policy.maxStaysPerPeriod else {
                return Resolved(policy: policy, staysUsedInWindow: 0, windowEndsAt: nil, counter: nil)
            }
            let counter = try await repository.fetchStayCounter(hostID: hostID, guestID: guestID)
            let used = counter?.spent(cap: cap) ?? 0
            let ends = (used > 0) ? counter?.windowEnd(cap: cap) : nil
            return Resolved(policy: policy, staysUsedInWindow: used, windowEndsAt: ends, counter: counter)
        } catch {
            log.error("resolve booking policy: \(error.localizedDescription, privacy: .public)")
            return .unrestricted
        }
    }

    /// The counter value a request being sent right now should carry, or nil
    /// when the policy is uncapped and no counter is needed. The rules accept
    /// exactly these two shapes — open a window, or increment the open one — so
    /// the write is never one they would have to turn down.
    func advancedCounter(
        for resolved: Resolved,
        hostID: String,
        guestID: String,
        now: Date = Date()
    ) -> StayCounter? {
        guard let cap = resolved.policy.maxStaysPerPeriod else { return nil }
        guard let existing = resolved.counter else {
            return StayCounter.opening(hostUserID: hostID, guestUserID: guestID, now: now)
        }
        return existing.advanced(cap: cap, now: now)
    }
}

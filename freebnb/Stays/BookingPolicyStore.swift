//
//  BookingPolicyStore.swift
//  freebnb
//
//  The guest's half of Circles, a different type from `CircleStore` so the compiler knows
//  the asymmetry: a host reads circles, memberships and overrides; a guest reads one
//  document, the policy a host resolved for them. Fetched on demand, not listened to: a
//  live listener would let a host tightening a policy change the guest's calendar
//  while they look, and a restricted friend must never be told. One read when the sheet
//  opens holds while it's up.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class BookingPolicyStore {
    /// What the request sheet needs: the applicable rules and how much of the frequency window is spent.
    struct Resolved: Equatable, Sendable {
        var policy: BookingPolicy
        /// Requests already made inside the open window; zero when it elapsed or there's no cap.
        var staysUsedInWindow: Int
        /// When the open window ends, if a cap is in force.
        var windowEndsAt: Date?
        /// The counter as it stands, so the sheet can hand the advanced value to the write.
        var counter: StayCounter?

        /// Nothing configured: every option offered, no days withheld.
        static let unrestricted = Resolved(policy: .permissive, staysUsedInWindow: 0, windowEndsAt: nil, counter: nil)
    }

    @ObservationIgnored private let repository: CircleRepository
    @ObservationIgnored private let log = AppLog.logger("circles")

    init(repository: CircleRepository = FirestoreCircleRepository()) {
        self.repository = repository
    }

    /// The policy `hostID` published for `guestID`, with the guest's frequency counter
    /// folded in. No policy or a failed read comes back unrestricted, the safe direction
    /// for a display decision since `firestore.rules` is what refuses.
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

    /// The counter value a request being sent now should carry, or nil when uncapped.
    /// The rules accept only open-a-window or increment-the-open-one.
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

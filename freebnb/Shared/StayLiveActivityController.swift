//
//  StayLiveActivityController.swift
//  freebnb
//
//  Drives the current-stay Live Activity (feature 21) off the same accepted-stay
//  set the store already syncs. It keeps at most one activity running — for the
//  most imminent live stay — starting it when a stay reaches its check-in day,
//  moving it through its phases, and ending it after checkout. All ActivityKit
//  work is behind `canImport` so a build without it (or a target that excludes
//  it) still compiles.
//

import Foundation
import os
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class StayLiveActivityController {
    private let log = AppLog.logger("liveactivity")

    /// Reconciles the running Live Activity with `stays`. Idempotent: safe to call
    /// on every snapshot. Picks the single stay that should be live now, then
    /// starts / updates / ends activities so exactly that one is showing.
    func sync(activeStays stays: [StayRequest], viewerID: String, now: Date = Date()) {
        #if canImport(ActivityKit)
        guard !viewerID.isEmpty else {
            Task { await endAll() }
            return
        }

        // The stay that should own the Live Activity right now: has a live phase,
        // and among those the soonest check-in.
        let target = stays
            .filter { $0.status == .accepted }
            .compactMap { stay -> (StayRequest, StayPhase)? in
                guard let phase = StayPhase.current(checkIn: stay.checkIn, checkOut: stay.checkOut, now: now) else { return nil }
                return (stay, phase)
            }
            .min { $0.0.checkIn < $1.0.checkIn }

        Task { await reconcile(target: target, viewerID: viewerID) }
        #endif
    }

    #if canImport(ActivityKit)
    private func reconcile(target: (StayRequest, StayPhase)?, viewerID: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // The user disabled Live Activities for the app; clean up and bail.
            await endAll()
            return
        }

        let running = Activity<StayActivityAttributes>.activities

        guard let (stay, phase) = target else {
            await endAll()
            return
        }

        // End any activity that isn't for the target stay (dates changed, a
        // different stay took over, or a stale one lingered).
        for activity in running where activity.attributes.stayID != stay.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let content = ActivityContent(
            state: StayActivityAttributes.ContentState(phase: phase),
            staleDate: nil
        )

        if let existing = running.first(where: { $0.attributes.stayID == stay.id }) {
            await existing.update(content)
            return
        }

        let attributes = StayActivityAttributes(
            stayID: stay.id,
            city: stay.listingCity,
            listingLabel: stay.listingLabel,
            checkIn: stay.checkIn,
            checkOut: stay.checkOut,
            isHost: stay.role(of: viewerID) == .host
        )
        do {
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            log.debug("started Live Activity for stay \(stay.id, privacy: .public)")
        } catch {
            log.error("failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endAll() async {
        for activity in Activity<StayActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    #endif
}

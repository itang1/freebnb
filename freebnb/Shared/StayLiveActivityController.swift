//
//  StayLiveActivityController.swift
//  freebnb
//
//  Drives the current-stay Live Activity from the accepted-stay set: at most one activity, for the most
//  imminent live
//  stay, started at check-in day, moved through phases and ended after checkout.
//

import ActivityKit
import Foundation
import os

@MainActor
final class StayLiveActivityController {
    private let log = AppLog.logger("liveactivity")

    /// Reconciles the running Live Activity with `stays`; idempotent, so safe on every snapshot. Picks the
    /// one live stay and starts/updates/ends to match.
    func sync(activeStays stays: [StayRequest], viewerID: String, now: Date = Date()) {
        guard !viewerID.isEmpty else {
            Task { await endAll() }
            return
        }

        // The stay that owns the activity now: has a live phase, soonest check-in among those.
        let target = stays
            .filter { $0.status == .accepted }
            .compactMap { stay -> (StayRequest, StayPhase)? in
                guard let phase = StayPhase.current(checkIn: stay.checkIn, checkOut: stay.checkOut, now: now) else { return nil }
                return (stay, phase)
            }
            .min { $0.0.checkIn < $1.0.checkIn }

        Task { await reconcile(target: target, viewerID: viewerID) }
    }

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

        // End any activity not for the target stay (dates changed, another took over, or a stale one lingered).
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
}

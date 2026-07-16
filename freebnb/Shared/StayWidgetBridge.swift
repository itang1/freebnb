//
//  StayWidgetBridge.swift
//  freebnb
//
//  Publishes the home-screen widget snapshot (feature 40, widget half). Turns the
//  store's live `StayRequest` arrays into the small `StayWidgetSnapshot` value,
//  writes it to the App Group, and pokes WidgetKit to reload. Pure translation
//  plus one side effect, so `makeSnapshot` is unit-testable on its own.
//

import Foundation
import WidgetKit
import os

@MainActor
enum StayWidgetBridge {
    private static let log = AppLog.logger("widgets")

    /// Recomputes the snapshot from the current requests and hands it to the
    /// widgets. Cheap and idempotent, so calling it on every Firestore snapshot
    /// (like the reminder sync) is fine.
    static func publish(incoming: [StayRequest], outgoing: [StayRequest], viewerID: String) {
        guard !viewerID.isEmpty else {
            // Signed out: clear the widgets rather than leave a stale trip up.
            StayWidgetSnapshot.empty.write()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let snapshot = makeSnapshot(incoming: incoming, outgoing: outgoing, viewerID: viewerID)
        snapshot.write()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("published widget snapshot: nextTrip=\(snapshot.nextTrip != nil, privacy: .public) pendingIn=\(snapshot.pendingIncomingCount, privacy: .public)")
    }

    /// The next stay worth surfacing plus the two pending counts. "Next" means the
    /// under-way stay if there is one, otherwise the soonest still-upcoming
    /// accepted stay, across both hosting and travelling.
    static func makeSnapshot(
        incoming: [StayRequest],
        outgoing: [StayRequest],
        viewerID: String,
        now: Date = Date()
    ) -> StayWidgetSnapshot {
        let all = incoming + outgoing

        let nextTrip = all
            .filter { $0.status == .accepted }
            .filter { $0.isUnderway(now: now) || $0.checkIn >= now }
            // Under-way stays sort ahead of upcoming ones; within each group the
            // soonest check-in wins. Tuple `<` gives exactly that ordering.
            .min { ($0.isUnderway(now: now) ? 0 : 1, $0.checkIn) < ($1.isUnderway(now: now) ? 0 : 1, $1.checkIn) }
            .map { trip in
                TripSummary(
                    stayID: trip.id,
                    city: trip.listingCity,
                    listingLabel: trip.listingLabel,
                    checkIn: trip.checkIn,
                    checkOut: trip.checkOut,
                    isHost: trip.role(of: viewerID) == .host
                )
            }

        return StayWidgetSnapshot(
            nextTrip: nextTrip,
            pendingIncomingCount: incoming.filter { $0.status == .pending }.count,
            pendingOutgoingCount: outgoing.filter { $0.status == .pending }.count,
            generatedAt: now
        )
    }
}

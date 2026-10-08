//
//  StayWidgetBridge.swift
//  freebnb
//
//  Publishes the widget snapshot: turns the stores' live `StayRequest` arrays into `StayWidgetSnapshot`, writes it to the App Group
//  and reloads WidgetKit. Pure translation plus one side effect, so `makeSnapshot` is unit-testable.
//

import Foundation
import WidgetKit
import os

@MainActor
enum StayWidgetBridge {
    private static let log = AppLog.logger("widgets")

    /// Recomputes the snapshot and hands it to the widgets; cheap and idempotent, so safe on every Firestore snapshot.
    static func publish(incoming: [StayRequest], outgoing: [StayRequest], viewerID: String) {
        guard !viewerID.isEmpty else {
            // Signed out: clear the widgets rather than leave a stale trip.
            StayWidgetSnapshot.empty.write()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let snapshot = makeSnapshot(incoming: incoming, outgoing: outgoing, viewerID: viewerID)
        snapshot.write()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("published widget snapshot: nextTrip=\(snapshot.nextTrip != nil, privacy: .public) pendingIn=\(snapshot.pendingIncomingCount, privacy: .public)")
    }

    /// The next stay worth surfacing plus the two pending counts: the under-way stay, else the soonest upcoming accepted one, across hosting and travelling.
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
            // Under-way sorts ahead of upcoming, soonest check-in within each; tuple `<` gives that.
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

//
//  CheckInKitStore.swift
//  freebnb
//
//  Keeps the on-disk check-in kits in step with the guest's accepted stays, as
//  `StayReminderScheduler` and `StayLiveActivityController` do: reconciled on every
//  snapshot, cheap and idempotent. Two directions, the second mattering more:
//   - stays lacking a kit → fetch the address and manual once, while there's a network.
//   - kits whose stay is gone → delete, since a local copy would outlive the server's address revocation.

import Foundation
import Observation
import os

@MainActor
@Observable
final class CheckInKitStore {
    /// The kits on disk, keyed by stay id; published so the card can say "saved for offline" without file reads.
    private(set) var kits: [String: CheckInKit] = [:]

    @ObservationIgnored private let files: CheckInKitFileStore
    @ObservationIgnored private let log = AppLog.logger("checkin")

    init(files: CheckInKitFileStore = CheckInKitFileStore()) {
        self.files = files
        // Load synchronously: a guest opening the app offline at the door must find the kit already there.
        kits = Dictionary(uniqueKeysWithValues: files.loadAll().map { ($0.stayID, $0) })
    }

    /// The kit for a stay, if one was saved.
    func kit(for stayID: String) -> CheckInKit? { kits[stayID] }

    /// The change key the view watches to call `sync`. Pure and out of ContentView
    /// because two properties are invisible at the call site. The viewer id leads, so
    /// signing out changes the key though a signed-out user has no stays (else the
    /// prune never runs). `authResolved` leads that, since at launch unresolved and
    /// signed-out both give an empty viewer id: the first must be ignored (kits belong
    /// to the user about to be restored) and the second must prune.
    static func changeKey(authResolved: Bool, viewerID: String, stays: [StayRequest]) -> [String] {
        ["auth-\(authResolved)", viewerID] + stays
            .filter { $0.status == .accepted }
            .map { "\($0.id)-\($0.checkIn.timeIntervalSince1970)-\($0.checkOut.timeIntervalSince1970)" }
    }

    /// Reconciles disk against the guest's stays. `fetch` supplies the address and
    /// manual as a closure, so the store has no opinion on the source and tests need no
    /// Firestore. Failures are silent: a kit that can't be built is a convenience lost, not worth an alert.
    func sync(
        stays: [StayRequest],
        viewerID: String,
        fetch: (String) async -> (Home, ListingLocation?, HouseManual?)?
    ) async {
        guard !viewerID.isEmpty else {
            // Signed out: the kits belong to whoever left; remove them so the next user doesn't see a door code.
            files.prune(keeping: [])
            kits = [:]
            return
        }

        // Only the guest's own accepted stays; a host has no use for a kit to their own home.
        let mine = stays.filter { $0.status == .accepted && $0.guestUserID == viewerID }
        let liveIDs = Set(mine.map(\.id))

        let removed = files.prune(keeping: liveIDs)
        for stayID in removed { kits.removeValue(forKey: stayID) }

        for stay in mine {
            guard let resolved = await fetch(stay.listingID) else { continue }
            let (home, location, manual) = resolved
            guard let kit = CheckInKit.make(stay: stay, home: home, location: location, manual: manual) else {
                // Nothing worth saving yet (no manual, address not fetched); keep any existing kit rather
                // than replace it with an empty one.
                continue
            }
            // Skip the write when only the timestamp changed, so snapshot storms don't rewrite secrets.
            if let existing = kits[stay.id], existing.isEquivalent(to: kit) { continue }
            files.save(kit)
            kits[stay.id] = kit
        }
    }
}

extension CheckInKit {
    /// Equality ignoring `savedAt`, which changes on every rebuild.
    func isEquivalent(to other: CheckInKit) -> Bool {
        var a = self
        var b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        return a == b
    }
}

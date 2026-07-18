//
//  CheckInKitStore.swift
//  freebnb
//
//  Keeps the on-disk check-in kits (feature 44) in step with the guest's accepted
//  stays, the same way `StayReminderScheduler` keeps local reminders in step and
//  `StayLiveActivityController` keeps the Live Activity in step: reconciled on
//  every snapshot, cheap and idempotent.
//
//  Two directions, and the second matters more than the first:
//   - stays the guest has and kits they lack → fetch the address and manual once
//     and write them down, while there is still a network to do it with.
//   - kits whose stay is gone → delete. The server revokes the address grant when
//     a stay ends; a local copy that outlived it would quietly undo that.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class CheckInKitStore {
    /// The kits currently on disk, keyed by stay id. Published so the logistics
    /// card can say "saved for offline" without a file read on every render.
    private(set) var kits: [String: CheckInKit] = [:]

    @ObservationIgnored private let files: CheckInKitFileStore
    @ObservationIgnored private let log = AppLog.logger("checkin")

    init(files: CheckInKitFileStore = CheckInKitFileStore()) {
        self.files = files
        // Load synchronously at init: a guest who opens the app offline at the
        // door must find the kit already there, not after a round trip that
        // cannot complete.
        kits = Dictionary(uniqueKeysWithValues: files.loadAll().map { ($0.stayID, $0) })
    }

    /// The kit for a stay, if one was saved.
    func kit(for stayID: String) -> CheckInKit? { kits[stayID] }

    /// Reconciles disk against the stays this guest actually has.
    ///
    /// `fetch` supplies the address and manual for a listing. It is a closure
    /// rather than a `HomeStore` dependency so this store has no opinion about
    /// where the data comes from, and so the tests don't need Firestore.
    ///
    /// Failures are silent by design: a kit that can't be built is a convenience
    /// the guest doesn't get, and the app has spent the whole stay working without
    /// one. What it must never do is throw an alert at someone about a file they
    /// didn't ask for.
    func sync(
        stays: [StayRequest],
        viewerID: String,
        fetch: (String) async -> (Home, ListingLocation?, HouseManual?)?
    ) async {
        guard !viewerID.isEmpty else {
            // Signed out: the kits belong to whoever just left. Take them off the
            // device rather than leaving one user's door code for the next.
            files.prune(keeping: [])
            kits = [:]
            return
        }

        // Only the guest's own accepted stays. A host has no use for a kit to
        // their own home, and building one would write their own address to disk
        // for no reason.
        let mine = stays.filter { $0.status == .accepted && $0.guestUserID == viewerID }
        let liveIDs = Set(mine.map(\.id))

        let removed = files.prune(keeping: liveIDs)
        for stayID in removed { kits.removeValue(forKey: stayID) }

        for stay in mine {
            guard let resolved = await fetch(stay.listingID) else { continue }
            let (home, location, manual) = resolved
            guard let kit = CheckInKit.make(stay: stay, home: home, location: location, manual: manual) else {
                // Nothing worth saving yet — most likely the host hasn't written a
                // manual and the address fetch hasn't landed. Leave any existing
                // kit alone rather than replacing a good one with an empty one.
                continue
            }
            // Skip the write when nothing changed but the timestamp, so a snapshot
            // storm doesn't rewrite the same secrets to disk over and over.
            if let existing = kits[stay.id], existing.isEquivalent(to: kit) { continue }
            files.save(kit)
            kits[stay.id] = kit
        }
    }
}

extension CheckInKit {
    /// Equality ignoring `savedAt`, which changes on every rebuild and would
    /// otherwise make every kit look new.
    func isEquivalent(to other: CheckInKit) -> Bool {
        var a = self
        var b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        return a == b
    }
}

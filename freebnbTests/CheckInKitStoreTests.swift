//
//  CheckInKitStoreTests.swift
//  freebnbTests
//
//  The reconciliation half of the check-in kit: which kits survive a sync and which
//  come off disk (`StayReminderTests` covers scheduling). The sign-out case is why it
//  exists: that branch was unreachable because its only caller was torn down on
//  sign-out, so door codes stayed and nothing failed.
//

import Foundation
import Testing
@testable import freebnb

private let guestID = "guest-1"

/// A kit with content, so `hasContent` holds and the store treats it as real.
private func kit(stayID: String, savedAt: Date = Date()) -> CheckInKit {
    CheckInKit(
        stayID: stayID,
        listingID: "listing-1",
        listingTitle: "The garden room",
        city: "Lisbon",
        state: "",
        hostName: "Sam",
        checkIn: Date(),
        checkOut: Date().addingTimeInterval(86_400 * 3),
        street: "12 Rua das Flores",
        checkInInstructions: "Door code is 1988.",
        wifiPassword: "hunter2",
        savedAt: savedAt
    )
}

/// A file store in a fresh temporary directory, isolated from each other and from Application Support.
private func temporaryFileStore() -> CheckInKitFileStore {
    let dir = URL.temporaryDirectory
        .appendingPathComponent("CheckInKitStoreTests-\(UUID().uuidString)", isDirectory: true)
    return CheckInKitFileStore(directory: dir)
}

/// Never called: these cases sign out or have no live stays, and neither fetches.
private func unusedFetch(_ listingID: String) async -> (Home, ListingLocation?, HouseManual?)? {
    Issue.record("fetch should not be called for \(listingID)")
    return nil
}

@MainActor
struct CheckInKitStoreTests {
    @Test func signOutTakesEveryKitOffTheDevice() async {
        let files = temporaryFileStore()
        files.save(kit(stayID: "stay-1"))
        files.save(kit(stayID: "stay-2"))

        let store = CheckInKitStore(files: files)
        #expect(store.kits.count == 2)

        // An empty viewer id is what a signed-out ContentView supplies.
        await store.sync(stays: [], viewerID: "", fetch: unusedFetch)

        #expect(store.kits.isEmpty)
        #expect(files.loadAll().isEmpty, "a departed user's door codes must not survive on disk")
    }

    @Test func signOutClearsKitsEvenWhenStaysStillArrive() async {
        // Sign-out ordering isn't guaranteed (auth may clear the viewer before the stay listener
        // drops its last snapshot), so the empty viewer id must decide, not the stays.
        let files = temporaryFileStore()
        files.save(kit(stayID: "stay-1"))
        let store = CheckInKitStore(files: files)

        await store.sync(stays: [staleStay(id: "stay-1")], viewerID: "", fetch: unusedFetch)

        #expect(store.kits.isEmpty)
        #expect(files.loadAll().isEmpty)
    }

    @Test func signedInGuestKeepsKitsForTheirOwnLiveStays() async {
        // The control: an unconditionally pruning store would pass both cases above.
        let files = temporaryFileStore()
        files.save(kit(stayID: "stay-1"))
        files.save(kit(stayID: "stay-gone"))
        let store = CheckInKitStore(files: files)

        // stay-1 is live; stay-gone is stale. No fetch runs since stay-1's kit is on disk and equivalent.
        await store.sync(stays: [staleStay(id: "stay-1")], viewerID: guestID) { _ in nil }

        #expect(store.kits.keys.sorted() == ["stay-1"])
        #expect(files.loadAll().map(\.stayID) == ["stay-1"])
    }

    // The store's sign-out branch was fine; the view never reached it. These pin the change key that makes it
    // reachable.

    @Test func signingOutChangesTheKeyEvenWithNoStays() {
        // The regression: a signed-out user has no stays, so without the viewer id both sides are `[]`, no
        // change, and door codes stay.
        let signedIn = CheckInKitStore.changeKey(authResolved: true, viewerID: guestID, stays: [])
        let signedOut = CheckInKitStore.changeKey(authResolved: true, viewerID: "", stays: [])
        #expect(signedIn != signedOut)
    }

    @Test func launchingBeforeAuthResolvesDoesNotLookLikeSigningOut() {
        // At launch the empty viewer id means "not known", not "nobody", and the caller skips
        // the sync; once Firebase answers the key must change, or a signed-out guest keeps old kits.
        let unresolved = CheckInKitStore.changeKey(authResolved: false, viewerID: "", stays: [])
        let signedOut = CheckInKitStore.changeKey(authResolved: true, viewerID: "", stays: [])
        #expect(unresolved != signedOut)
    }

    @Test func switchingUsersChangesTheKeyWithIdenticalStays() {
        // On a shared device the same stay list mustn't make two viewers look alike.
        let stays = [staleStay(id: "stay-1")]
        #expect(
            CheckInKitStore.changeKey(authResolved: true, viewerID: guestID, stays: stays)
                != CheckInKitStore.changeKey(authResolved: true, viewerID: "guest-2", stays: stays)
        )
    }

    @Test func anUnrelatedSnapshotLeavesTheKeyAlone() {
        // The key avoids re-syncing on every snapshot, so a pending stay arriving mustn't disturb it.
        let live = staleStay(id: "stay-1")
        let pending = StayRequest(
            listingID: "listing-2",
            listingCity: "Porto",
            listingHostName: "Ana",
            hostUserID: "host-2",
            guestUserID: guestID,
            checkIn: Date(),
            checkOut: Date().addingTimeInterval(86_400),
            status: .pending
        )
        #expect(
            CheckInKitStore.changeKey(authResolved: true, viewerID: guestID, stays: [live])
                == CheckInKitStore.changeKey(authResolved: true, viewerID: guestID, stays: [live, pending])
        )
    }

    @Test func aHostGetsNoKitForTheirOwnHome() async {
        let files = temporaryFileStore()
        let store = CheckInKitStore(files: files)

        // The viewer hosts this stay, so a kit would write their own address to disk for no reason.
        let stay = StayRequest(
            listingID: "listing-1",
            listingCity: "Lisbon",
            listingHostName: "Sam",
            hostUserID: guestID,
            guestUserID: "someone-else",
            checkIn: Date(),
            checkOut: Date().addingTimeInterval(86_400 * 3),
            status: .accepted
        )

        await store.sync(stays: [stay], viewerID: guestID, fetch: unusedFetch)

        #expect(store.kits.isEmpty)
    }
}

/// An accepted stay for `guestID`, with dates that do not matter to these cases.
private func staleStay(id: String) -> StayRequest {
    StayRequest(
        id: id,
        listingID: "listing-1",
        listingCity: "Lisbon",
        listingHostName: "Sam",
        hostUserID: "host-1",
        guestUserID: guestID,
        checkIn: Date(),
        checkOut: Date().addingTimeInterval(86_400 * 3),
        status: .accepted
    )
}

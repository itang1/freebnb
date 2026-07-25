//
//  CheckInKitStoreTests.swift
//  freebnbTests
//
//  The reconciliation half of feature 44: which kits survive a sync and which
//  come off the disk. `StayReminderTests` covers the pure scheduling decisions
//  next door; this covers the one that writes secrets to a file.
//
//  The sign-out case is the reason this file exists. `CheckInKitStore.sync` has
//  always had a "signed out, take the kits off the device" branch, but its only
//  caller lived inside ContentView's `isSignedIn` branch — torn down on sign-out
//  before it could fire — so the branch was unreachable and the door codes
//  stayed. Nothing failed, because nothing asked.
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

/// A file store rooted in a fresh temporary directory, so cases cannot see each
/// other's files and none of this touches the real Application Support folder.
private func temporaryFileStore() -> CheckInKitFileStore {
    let dir = URL.temporaryDirectory
        .appendingPathComponent("CheckInKitStoreTests-\(UUID().uuidString)", isDirectory: true)
    return CheckInKitFileStore(directory: dir)
}

/// Never called: every case here either signs out or has no live stays, and
/// neither path fetches. A kit that needs building would be a different test.
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
        // The sign-out ordering is not guaranteed: the auth listener may clear the
        // viewer before the stay listener drops its last snapshot. The empty
        // viewer id has to be what decides, not the stays.
        let files = temporaryFileStore()
        files.save(kit(stayID: "stay-1"))
        let store = CheckInKitStore(files: files)

        await store.sync(stays: [staleStay(id: "stay-1")], viewerID: "", fetch: unusedFetch)

        #expect(store.kits.isEmpty)
        #expect(files.loadAll().isEmpty)
    }

    @Test func signedInGuestKeepsKitsForTheirOwnLiveStays() async {
        // The control. Without it a store that pruned unconditionally would pass
        // both cases above.
        let files = temporaryFileStore()
        files.save(kit(stayID: "stay-1"))
        files.save(kit(stayID: "stay-gone"))
        let store = CheckInKitStore(files: files)

        // stay-1 is live; stay-gone is not in the list, so it is stale. No fetch
        // runs because stay-1's kit is already on disk and equivalent.
        await store.sync(stays: [staleStay(id: "stay-1")], viewerID: guestID) { _ in nil }

        #expect(store.kits.keys.sorted() == ["stay-1"])
        #expect(files.loadAll().map(\.stayID) == ["stay-1"])
    }

    // The store's sign-out branch was correct all along; what was broken was the
    // view never reaching it. These pin the change key that makes it reachable.

    @Test func signingOutChangesTheKeyEvenWithNoStays() {
        // The regression in one line. A signed-out user has no stays, so without
        // the viewer id both sides are `[]`, SwiftUI sees no change, `sync` never
        // runs, and the door codes stay on the device.
        let signedIn = CheckInKitStore.changeKey(viewerID: guestID, stays: [])
        let signedOut = CheckInKitStore.changeKey(viewerID: "", stays: [])
        #expect(signedIn != signedOut)
    }

    @Test func switchingUsersChangesTheKeyWithIdenticalStays() {
        // The shared-device case: the same stay list cannot make two different
        // viewers look alike, or the second user's sync would be skipped.
        let stays = [staleStay(id: "stay-1")]
        #expect(
            CheckInKitStore.changeKey(viewerID: guestID, stays: stays)
                != CheckInKitStore.changeKey(viewerID: "guest-2", stays: stays)
        )
    }

    @Test func anUnrelatedSnapshotLeavesTheKeyAlone() {
        // The other half of the bargain: the key exists to avoid re-syncing on
        // every snapshot, so a pending stay arriving must not disturb it.
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
            CheckInKitStore.changeKey(viewerID: guestID, stays: [live])
                == CheckInKitStore.changeKey(viewerID: guestID, stays: [live, pending])
        )
    }

    @Test func aHostGetsNoKitForTheirOwnHome() async {
        let files = temporaryFileStore()
        let store = CheckInKitStore(files: files)

        // The viewer hosts this stay rather than taking it. Building a kit would
        // write the host's own address to their own disk for no reason.
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

//
//  FirestoreHomesRepositoryEmulatorTests.swift
//  freebnbTests
//
//  Runs the real FirestoreHomesRepository against the Local Emulator Suite, so
//  it covers what the in-memory doubles cannot: that firestore.rules actually
//  admit a full member's listing and reject a guest's, and that the recency
//  cursor pages against a live composite index.
//
//  Gated on the emulator being reachable (see EmulatorSupport) so the suite is
//  inert on any build that isn't running under `firebase emulators:exec`, and
//  serialized because the tests share one Auth session on the secondary app.
//

import FirebaseFirestore
import Foundation
import Testing
@testable import freebnb

@Suite(.serialized, .enabled(if: EmulatorSupport.isEmulatorReachable))
struct FirestoreHomesRepositoryEmulatorTests {

    private var repository: FirestoreHomesRepository {
        FirestoreHomesRepository(db: EmulatorSupport.firestore)
    }

    // A full member (email/password) may create a listing, and it comes back in
    // their feed — the create rule and the visibility read rule both pass.
    @Test func fullMemberCreatesAndReadsOwnListing() async throws {
        let uid = try await EmulatorSupport.signInFullMember()
        let home = makeHome(hostUserID: uid)

        try await repository.save(home)

        let feed = try await repository.fetchVisibleListings(viewerID: uid, after: nil, limit: 100)
        #expect(feed.contains { $0.id == home.id })
    }

    // Two listings created in sequence come back newest-first, and the recency
    // cursor advances past the first page instead of repeating it.
    @Test func feedOrdersByRecencyAndCursorAdvances() async throws {
        let uid = try await EmulatorSupport.signInFullMember()
        let older = makeHome(hostUserID: uid)
        try await repository.save(older)
        let newer = makeHome(hostUserID: uid)
        try await repository.save(newer)

        // Robust to other tests' data: assert only the relative order of the two
        // listings this test created.
        let feed = try await repository.fetchVisibleListings(viewerID: uid, after: nil, limit: 100)
        let mine = feed.filter { $0.id == older.id || $0.id == newer.id }.map(\.id)
        #expect(mine == [newer.id, older.id])

        // The cursor from page one must not re-yield the same document.
        let firstPage = try await repository.fetchVisibleListings(viewerID: uid, after: nil, limit: 1)
        let first = try #require(firstPage.first)
        let cursor = ListingCursor(createdAt: try #require(first.createdAt), id: first.id)
        let secondPage = try await repository.fetchVisibleListings(viewerID: uid, after: cursor, limit: 1)
        #expect(secondPage.first?.id != first.id)
    }

    // The guest-write boundary is a real rules boundary, not just a UI one: an
    // anonymous user's create is denied, so save() throws (permission-denied is
    // non-transient, so withRetry surfaces it immediately).
    @Test func guestCannotCreateListing() async throws {
        let uid = try await EmulatorSupport.signInGuest()
        let home = makeHome(hostUserID: uid)

        await #expect(throws: (any Error).self) {
            try await repository.save(home)
        }
    }

    // MARK: - Fixtures

    private func makeAmenities() -> Amenities {
        Amenities(
            hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
            hasMicrowave: false, hasTV: false, hasWifi: false,
            hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
            hasInUnitLaundry: false, hasCoinLaundryNearby: false,
            providesPillows: false, providesBlankets: false, providesTowels: false,
            providesToiletries: false, foodProvision: .none
        )
    }

    private func makeHome(hostUserID: String, id: String = UUID().uuidString) -> Home {
        var home = Home(
            hostUserID: hostUserID,
            hostName: "Emulator Host",
            address: Address(city: "Town", state: "CA", zip: "00000"),
            description: nil,
            contactPreference: .inApp,
            hostContactInfo: nil,
            hostMotivation: .open,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
            amenities: makeAmenities()
        )
        home.id = id
        home.visibility = .everyone
        // Mirrors what the app stamps on save so the read rule's allowedViewerIDs
        // clause is satisfied for the host as well as the public-visibility one.
        home.allowedViewerIDs = [hostUserID]
        return home
    }
}

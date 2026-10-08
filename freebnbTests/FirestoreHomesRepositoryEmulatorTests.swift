//
//  FirestoreHomesRepositoryEmulatorTests.swift
//  freebnbTests
//
//  Runs the real FirestoreHomesRepository against the emulator, covering what the in-memory doubles
//  can't: the rules admitting a full member's listing and rejecting a guest's, and the recency cursor
//  paging against a live composite index. Nested in EmulatorBackedTests (shares one Auth session with
//  AuthEmulatorTests).
//

import FirebaseFirestore
import Foundation
import Testing
@testable import freebnb

extension EmulatorBackedTests {
    @Suite
    struct FirestoreHomesRepositoryEmulatorTests {

        private var repository: FirestoreHomesRepository {
            FirestoreHomesRepository(db: EmulatorSupport.firestore)
        }

        // A full member may create a listing and see it in their feed (create and ACL read rules both pass).
        @Test func fullMemberCreatesAndReadsOwnListing() async throws {
            let uid = try await EmulatorSupport.signInFullMember()
            let home = makeHome(hostUserID: uid)

            try await repository.save(home)

            let feed = try await repository.fetchVisibleListings(viewerID: uid, after: nil, limit: 100)
            #expect(feed.contains { $0.id == home.id })
        }

        // Two listings come back newest-first, and the cursor advances past page one instead of repeating.
        @Test func feedOrdersByRecencyAndCursorAdvances() async throws {
            let uid = try await EmulatorSupport.signInFullMember()
            let older = makeHome(hostUserID: uid)
            try await repository.save(older)
            let newer = makeHome(hostUserID: uid)
            try await repository.save(newer)

            // Robust to other tests' data: assert only the relative order of this test's two listings.
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

        // The guest-write boundary is a rules boundary: an anonymous create is denied, and permission-denied
        // isn't retried.
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
            // Mirrors what the app stamps on save, satisfying the read rule's allowedViewerIDs for the host.
            home.allowedViewerIDs = [hostUserID]
            return home
        }
    }
}

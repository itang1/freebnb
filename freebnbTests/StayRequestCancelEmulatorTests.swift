//
//  StayRequestCancelEmulatorTests.swift
//  freebnbTests
//
//  The cancel write, from the real repository against the real rules (R3).
//
//  `cancelledBy` is pinned by firestore.rules to the party doing the cancelling,
//  which means the exact key set the client sends has to line up with what those
//  rules admit. The Node rules tests cover the rules; they cover them against a
//  payload written by hand. This covers the payload the app actually sends — the
//  half that, if it were wrong, would let cancelling fail silently in prod while
//  every other test stayed green.
//
//  Nested in EmulatorBackedTests for the opt-in gate and the serialization.
//

import FirebaseFirestore
import Foundation
import Testing
@testable import freebnb

extension EmulatorBackedTests {
    @Suite
    struct StayRequestCancelEmulatorTests {

        private var requests: FirestoreStayRequestsRepository {
            FirestoreStayRequestsRepository(db: EmulatorSupport.firestore)
        }

        private var homes: FirestoreHomesRepository {
            FirestoreHomesRepository(db: EmulatorSupport.firestore)
        }

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

        /// A host with a listing shared with `guestUserID`, and a pending request
        /// from that guest against it — the furthest this can get through the real
        /// rules without the acceptStayRequest callable, which the emulator-tests
        /// project has no functions for.
        private func makePendingRequest() async throws -> (guest: EmulatorSupport.Member, request: StayRequest) {
            let guest = try await EmulatorSupport.createFullMember()
            let hostID = try await EmulatorSupport.signInFullMember()

            var home = Home(
                hostUserID: hostID,
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
            home.id = UUID().uuidString
            // The guest has to be in the read ACL to be allowed to knock at all.
            home.allowedViewerIDs = [hostID, guest.uid]
            try await homes.save(home)

            try await EmulatorSupport.signIn(as: guest)
            let request = StayRequest(
                listingID: home.id,
                listingCity: home.address.city,
                listingHostName: home.hostName,
                hostUserID: hostID,
                guestUserID: guest.uid,
                checkIn: Date().addingTimeInterval(5 * 86_400),
                checkOut: Date().addingTimeInterval(7 * 86_400)
            )
            try await requests.create(request, advancing: nil)
            return (guest, request)
        }

        private func storedRequest(_ id: String) async throws -> [String: Any]? {
            try await EmulatorSupport.firestore
                .collection(FirestorePaths.stayRequests).document(id).getDocument().data()
        }

        // The whole point: the repository's own cancel payload is accepted, and
        // it records who cancelled.
        @Test func aGuestCancelIsAcceptedAndNamesTheGuest() async throws {
            let (guest, request) = try await makePendingRequest()

            try await requests.updateStatus(request, status: .cancelled, hostNote: nil, guestNote: nil, cancelledBy: guest.uid)

            let stored = try await storedRequest(request.id)
            #expect(stored?["status"] as? String == "cancelled")
            #expect(stored?["cancelledBy"] as? String == guest.uid)
        }

        // The field is only worth reading if it cannot lie: a guest must not be
        // able to cancel and pin it on the host, which would push the wrong
        // person and tell them they backed out of their own stay.
        @Test func aGuestCannotBlameTheHostForTheirOwnCancellation() async throws {
            let (_, request) = try await makePendingRequest()

            await #expect(throws: (any Error).self) {
                try await requests.updateStatus(
                    request, status: .cancelled, hostNote: nil, guestNote: nil, cancelledBy: request.hostUserID
                )
            }
        }

        // An unattributed cancellation would leave the trigger unable to tell who
        // already knows, so the rules refuse it rather than let it through silent.
        @Test func aCancelWithNoCancellerIsRejected() async throws {
            let (_, request) = try await makePendingRequest()

            await #expect(throws: (any Error).self) {
                try await requests.updateStatus(request, status: .cancelled, hostNote: nil, guestNote: nil, cancelledBy: nil)
            }
        }
    }
}

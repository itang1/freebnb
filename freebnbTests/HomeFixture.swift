//
//  HomeFixture.swift
//  freebnbTests
//
//  A shared `Home` builder for the tests whose fixtures only differ by a handful
//  of fields (id, host, reach, coordinate, timestamps). It replaces the copies
//  of the same `makeHome`/`makeAmenities` that had drifted across the suite.
//
//  Namespaced as `HomeFixture.make` on purpose: three tests keep a private
//  `makeHome` because their fixture is tuned to what they assert, and a free
//  function of the same name would make those call sites ambiguous.
//    - ListingDraftTests: a rich Pasadena listing whose fields it reads back.
//    - SpotlightIndexerTests: Portland/OR defaults its title and keyword tests rely on.
//    - TrustAndSafetyTests: a fixed `createdAt`.
//

import Foundation
@testable import freebnb

enum HomeFixture {
    /// Every amenity off. Tests that care about a specific amenity set it on the
    /// returned `Home`; none of the callers here read amenities at all.
    static func amenities() -> Amenities {
        Amenities(
            hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
            hasMicrowave: false, hasTV: false, hasWifi: false,
            hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
            hasInUnitLaundry: false, hasCoinLaundryNearby: false,
            providesPillows: false, providesBlankets: false, providesTowels: false,
            providesToiletries: false, foodProvision: .none
        )
    }

    /// A minimal "Town, CA" listing. `id` defaults to a fresh UUID so a test that
    /// builds several homes without naming them never collides on the same id.
    static func make(
        id: String = UUID().uuidString,
        hostUserID: String = "host",
        hostName: String = "Host",
        city: String = "Town",
        coordinate: Coordinate? = nil,
        coHosts: [String]? = nil,
        allowedViewerIDs: [String]? = nil,
        deletedAt: Date? = nil,
        createdAt: Date? = nil
    ) -> Home {
        var home = Home(
            hostUserID: hostUserID,
            hostName: hostName,
            address: Address(city: city, state: "CA", zip: "00000"),
            description: nil,
            contactPreference: .inApp,
            hostContactInfo: nil,
            hostMotivation: .open,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
            amenities: amenities()
        )
        home.id = id
        home.coHostUserIDs = coHosts
        home.allowedViewerIDs = allowedViewerIDs
        home.deletedAt = deletedAt
        home.createdAt = createdAt
        home.latitude = coordinate?.latitude
        home.longitude = coordinate?.longitude
        return home
    }
}

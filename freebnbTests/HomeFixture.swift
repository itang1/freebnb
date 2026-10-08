//
//  HomeFixture.swift
//  freebnbTests
//
//  A shared `Home` builder for tests whose fixtures differ by a few fields, replacing the drifted `makeHome`
//  copies. Namespaced as `HomeFixture.make` because three tests keep a private `makeHome` tuned to their
//  assertions
//  (ListingDraftTests, SpotlightIndexerTests, TrustAndSafetyTests), and a free function would be ambiguous.
//

import Foundation
@testable import freebnb

enum HomeFixture {
    /// Every amenity off; tests that care set it on the returned `Home`.
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

    /// A minimal "Town, CA" listing; `id` defaults to a fresh UUID so unnamed homes never collide.
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

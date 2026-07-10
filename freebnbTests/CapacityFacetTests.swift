//
//  CapacityFacetTests.swift
//  freebnbTests
//
//  Covers the richer capacity data (feature 17): bathroom counts, bed sizes, and
//  accessibility attributes.
//
//  Two things are load-bearing here. First, back-compatible decoding: these keys
//  post-date the schema, and a listing that fails to decode is dropped silently
//  from the feed (A5), so a listing saved before them must still come back. Second,
//  the meaning of a missing value — an unanswered question, never an answer of
//  "no". That distinction decides what the filters match and what the UI renders.
//

import Foundation
import Testing
@testable import freebnb

/// A listing document as it looked before feature 17: no `numBathrooms`, no
/// `bedSizes`, no accessibility keys.
private let legacyListingJSON = """
{
  "hostUserID": "host",
  "hostName": "Host",
  "address": { "city": "Pasadena", "state": "CA", "zip": "91103" },
  "sleeping": { "numGuestRooms": 1, "arrangements": { "bed": 1 } },
  "guestPolicy": { "maxGuests": 2, "maxStayDays": 7, "kidsAllowed": true, "guestPetsAllowed": false },
  "amenities": {
    "hasAC": true, "hasHeating": true, "hasKitchen": true, "hasFridgeSpace": false,
    "hasMicrowave": false, "hasTV": false, "hasWifi": true,
    "hasPrivateGuestBathroom": true, "hostHasPets": false, "parkingDetails": "Street",
    "hasInUnitLaundry": false, "hasCoinLaundryNearby": true,
    "providesPillows": true, "providesBlankets": true, "providesTowels": false,
    "providesToiletries": false, "foodProvision": "some"
  }
}
"""

struct LegacyListingDecodingTests {
    private func decodeLegacy() throws -> Home {
        try JSONDecoder().decode(Home.self, from: Data(legacyListingJSON.utf8))
    }

    /// The whole point of the tolerant decoders: a pre-feature-17 listing must
    /// still decode, or it silently disappears from the feed.
    @Test func listingSavedBeforeFeature17StillDecodes() throws {
        let home = try decodeLegacy()
        #expect(home.sleeping.numGuestRooms == 1)
        #expect(home.amenities.hasWifi)
    }

    /// Zero bathrooms is "the host never said". The card and detail page key off
    /// this to omit the row rather than print "Bathrooms: 0".
    @Test func legacyListingReportsNoBathroomCountRatherThanOne() throws {
        #expect(try decodeLegacy().sleeping.numBathrooms == 0)
    }

    @Test func legacyListingHasNoBedSizesAndSoNoBedForTwo() throws {
        let sleeping = try decodeLegacy().sleeping
        #expect(sleeping.bedSizeCounts.isEmpty)
        #expect(!sleeping.hasBedForTwo)
    }

    /// False here means "did not claim", which is why nothing renders a red X.
    @Test func legacyListingClaimsNoAccessibility() throws {
        let amenities = try decodeLegacy().amenities
        #expect(!amenities.hasStepFreeEntry)
        #expect(!amenities.hasElevator)
        #expect(!amenities.hasAccessibleBathroom)
        #expect(!amenities.hasAnyAccessibility)
    }

    /// Encoding a decoded listing and decoding it back must preserve the new
    /// fields; the custom decoders sit alongside a synthesized encoder, and it is
    /// easy for the two to drift apart on a key.
    @Test func newFieldsSurviveAnEncodeDecodeRoundTrip() throws {
        var home = try decodeLegacy()
        home.sleeping.numBathrooms = 2
        home.sleeping.bedSizes = ["queen": 1]
        home.amenities.hasStepFreeEntry = true
        home.amenities.hasElevator = true

        let data = try JSONEncoder().encode(home)
        let restored = try JSONDecoder().decode(Home.self, from: data)

        #expect(restored.sleeping.numBathrooms == 2)
        #expect(restored.sleeping.bedSizeCounts == [.queen: 1])
        #expect(restored.amenities.hasStepFreeEntry)
        #expect(restored.amenities.hasElevator)
        #expect(!restored.amenities.hasAccessibleBathroom)
    }
}

struct BedSizeTests {
    @Test func onlyQueenAndKingSleepTwo() {
        #expect(!BedSize.twin.sleepsTwo)
        #expect(!BedSize.full.sleepsTwo)
        #expect(BedSize.queen.sleepsTwo)
        #expect(BedSize.king.sleepsTwo)
    }

    @Test func bedSizeCountsDropUnknownRawValuesAndNonPositiveCounts() {
        let sleeping = Sleeping(
            numGuestRooms: 1,
            arrangements: ["bed": 3],
            bedSizes: ["queen": 1, "waterbed": 1, "twin": 0, "king": 2]
        )
        #expect(sleeping.bedSizeCounts == [.queen: 1, .king: 2])
    }

    @Test func hasBedForTwoOnlyWhenAQueenOrKingIsPresent() {
        let twins = Sleeping(numGuestRooms: 1, arrangements: ["bed": 2], bedSizes: ["twin": 2])
        #expect(!twins.hasBedForTwo)

        let queen = Sleeping(numGuestRooms: 1, arrangements: ["bed": 1], bedSizes: ["queen": 1])
        #expect(queen.hasBedForTwo)
    }

    /// Smallest first, so "1 king, 2 twins" never reads as if the twins came free
    /// with the king.
    @Test func bedSizesDescriptionOrdersSmallestFirstAndPluralises() {
        let sleeping = Sleeping(
            numGuestRooms: 1,
            arrangements: ["bed": 3],
            bedSizes: ["king": 1, "twin": 2]
        )
        #expect(sleeping.bedSizesDescription == "2 twins, 1 king")
    }
}

struct CapacityFilterTests {
    private func home(_ configure: (inout Home) -> Void) -> Home {
        var home = Home(
            hostUserID: "host",
            hostName: "Host",
            address: Address(city: "Town", state: "CA", zip: "00000"),
            description: nil,
            contactPreference: .inApp,
            hostContactInfo: nil,
            hostMotivation: .open,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
            amenities: Amenities(
                hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
                hasMicrowave: false, hasTV: false, hasWifi: false,
                hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
                hasInUnitLaundry: false, hasCoinLaundryNearby: false,
                providesPillows: false, providesBlankets: false, providesTowels: false,
                providesToiletries: false, foodProvision: .none
            )
        )
        configure(&home)
        return home
    }

    private func filter(_ id: String) throws -> FilterOption {
        try #require(FilterOption.all.first { $0.id == id })
    }

    /// A listing that never recorded a bed size cannot claim a queen. A guest
    /// filtering for one has said plainly that a maybe is not good enough.
    @Test func queenOrKingFilterExcludesListingsThatNeverSaid() throws {
        let option = try filter("bedForTwo")
        #expect(!option.matches(home { _ in }))
        #expect(option.matches(home { $0.sleeping.bedSizes = ["king": 1] }))
        #expect(!option.matches(home { $0.sleeping.bedSizes = ["twin": 2] }))
    }

    /// Same logic for bathrooms: an unspecified count is not two.
    @Test func twoBathroomsFilterExcludesUnspecifiedCounts() throws {
        let option = try filter("twoBathrooms")
        #expect(!option.matches(home { _ in }))
        #expect(!option.matches(home { $0.sleeping.numBathrooms = 1 }))
        #expect(option.matches(home { $0.sleeping.numBathrooms = 2 }))
    }

    @Test func accessibilityFiltersMatchOnlyClaimedAttributes() throws {
        let stepFree = try filter("stepFreeEntry")
        #expect(!stepFree.matches(home { _ in }))
        #expect(stepFree.matches(home { $0.amenities.hasStepFreeEntry = true }))
        // An elevator is not a step-free entrance, and must not stand in for one.
        #expect(!stepFree.matches(home { $0.amenities.hasElevator = true }))
    }

    @Test func accessibilityFiltersAreTheirOwnCategory() {
        let ids = FilterOption.options(for: .accessibility).map(\.id)
        #expect(ids == ["stepFreeEntry", "elevator", "accessibleBathroom"])
    }

    /// Ranking homes by accessibility would push accessible listings up the feed
    /// for guests who never asked. It is a fact about a home, not a perk.
    @Test func accessibilityDoesNotInflateTheAmenityCount() {
        let plain = home { _ in }
        let accessible = home {
            $0.amenities.hasStepFreeEntry = true
            $0.amenities.hasElevator = true
            $0.amenities.hasAccessibleBathroom = true
        }
        #expect(plain.amenities.count == accessible.amenities.count)
    }
}

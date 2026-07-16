//
//  SpotlightIndexerTests.swift
//  freebnbTests
//
//  The pure attribute builders behind saved-listing Spotlight indexing
//  (feature 40). The live CSSearchableIndex isn't driven here — only what we hand
//  it, which is the part that must be correct and privacy-safe.
//

import Testing
@testable import freebnb

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

private func makeHome(
    id: String = "home-1",
    hostName: String = "Shai",
    city: String = "Portland",
    state: String = "OR",
    description: String? = nil
) -> Home {
    var home = Home(
        hostUserID: "host",
        hostName: hostName,
        address: Address(city: city, state: state, zip: "97201"),
        description: description,
        contactPreference: .inApp,
        hostContactInfo: nil,
        hostMotivation: .open,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
        amenities: makeAmenities()
    )
    home.id = id
    return home
}

struct SpotlightIndexerTests {
    @Test func titleCombinesHostAndNeighbourhood() {
        let home = makeHome(hostName: "Shai", city: "Portland", state: "OR")
        #expect(SpotlightIndexer.title(for: home) == "Shai · Portland, OR")
    }

    @Test func descriptionUsesHostWordsWhenPresent() {
        let home = makeHome(description: "  Sunny spare room  ")
        #expect(SpotlightIndexer.contentDescription(for: home) == "Sunny spare room")
    }

    @Test func descriptionFallsBackWhenBlank() {
        let empty = makeHome(city: "Austin", state: "TX", description: "   ")
        #expect(SpotlightIndexer.contentDescription(for: empty) == "A place to stay in Austin, TX.")
        let nilDesc = makeHome(city: "Austin", state: "TX", description: nil)
        #expect(SpotlightIndexer.contentDescription(for: nilDesc) == "A place to stay in Austin, TX.")
    }

    @Test func keywordsCoverCityStateAndHost() {
        let home = makeHome(hostName: "Shai", city: "Portland", state: "OR")
        let keywords = SpotlightIndexer.keywords(for: home)
        #expect(keywords.contains("Portland"))
        #expect(keywords.contains("OR"))
        #expect(keywords.contains("Shai"))
    }

    @Test func itemUsesListingIDAsUniqueIdentifier() {
        // The deep link back into the app relies on the id round-tripping.
        let home = makeHome(id: "listing-42")
        let item = SpotlightIndexer.item(for: home)
        #expect(item.uniqueIdentifier == "listing-42")
        #expect(item.domainIdentifier == SpotlightIndexer.domainIdentifier)
    }

    @Test func descriptionNeverLeaksAnAddressField() {
        // Sanity: the builder only reads public card fields, never the private
        // street. There is no street on Home to read, but this pins the contract.
        let home = makeHome(description: "Near downtown")
        #expect(SpotlightIndexer.contentDescription(for: home) == "Near downtown")
    }
}

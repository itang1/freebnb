//
//  FeedSectionsTests.swift
//  freebnbTests
//
//  Covers the two pure derivations behind the feed's explanatory chips (feature
//  18) and the "new from your network" rail (feature 10). The chip makes a claim
//  about who knows whom, so the cases that matter most here are the ones where it
//  must stay silent.
//

import Foundation
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
    id: String,
    hostUserID: String,
    visibility: ListingVisibility? = nil,
    allowedViewerIDs: [String]? = nil,
    createdAt: Date? = nil
) -> Home {
    var home = Home(
        hostUserID: hostUserID,
        hostName: "Host",
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
    home.visibility = visibility
    home.allowedViewerIDs = allowedViewerIDs
    home.createdAt = createdAt
    return home
}

struct FeedReasonTests {
    private let me = "me"
    private let friends: Set<String> = ["friend"]

    @Test func ownListingIsLabelledAsYours() {
        let home = makeHome(id: "a", hostUserID: me)
        #expect(FeedSections.reason(for: home, myID: me, friendIDs: friends) == .yourListing)
    }

    @Test func friendsListingIsLabelledAsFriend() {
        let home = makeHome(id: "a", hostUserID: "friend")
        #expect(FeedSections.reason(for: home, myID: me, friendIDs: friends) == .friend)
    }

    /// The friend edge outranks the ACL: a direct friend whose listing is set to
    /// friends-of-friends is still, plainly, a friend.
    @Test func directFriendOutranksFriendOfFriendACL() {
        let home = makeHome(
            id: "a",
            hostUserID: "friend",
            visibility: .friendsOfFriends,
            allowedViewerIDs: [me]
        )
        #expect(FeedSections.reason(for: home, myID: me, friendIDs: friends) == .friend)
    }

    /// The only second-degree connection the client can prove: the server wrote
    /// the viewer into the listing's ACL.
    @Test func friendOfFriendRequiresBothTheVisibilityAndTheACL() {
        let inACL = makeHome(id: "a", hostUserID: "stranger", visibility: .friendsOfFriends, allowedViewerIDs: [me])
        #expect(FeedSections.reason(for: inACL, myID: me, friendIDs: friends) == .friendOfFriend)

        let notInACL = makeHome(id: "b", hostUserID: "stranger", visibility: .friendsOfFriends, allowedViewerIDs: ["someone"])
        #expect(FeedSections.reason(for: notInACL, myID: me, friendIDs: friends) == nil)

        let noACL = makeHome(id: "c", hostUserID: "stranger", visibility: .friendsOfFriends)
        #expect(FeedSections.reason(for: noACL, myID: me, friendIDs: friends) == nil)
    }

    /// A public listing carries no second-degree marker even when its host really
    /// is a friend of a friend, so it must not claim one.
    @Test func publicListingFromAStrangerGetsNoChip() {
        let everyone = makeHome(id: "a", hostUserID: "stranger", visibility: .everyone, allowedViewerIDs: [me])
        #expect(FeedSections.reason(for: everyone, myID: me, friendIDs: friends) == nil)

        let legacy = makeHome(id: "b", hostUserID: "stranger")
        #expect(FeedSections.reason(for: legacy, myID: me, friendIDs: friends) == nil)
    }

    /// An anonymous browser has no network, so nothing about the graph is true of
    /// them — including, importantly, that an ACL entry for "" means anything.
    @Test func signedOutViewerNeverEarnsAChip() {
        let ownedByEmptyString = makeHome(id: "a", hostUserID: "", visibility: .friendsOfFriends, allowedViewerIDs: [""])
        #expect(FeedSections.reason(for: ownedByEmptyString, myID: "", friendIDs: []) == nil)
    }
}

struct NetworkRailTests {
    private let me = "me"
    private let friends: Set<String> = ["friend"]
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 60 * 60)
    }

    private func rail(_ homes: [Home], limit: Int = FeedSections.railLimit) -> [String] {
        FeedSections.newFromYourNetwork(homes, myID: me, friendIDs: friends, now: now, limit: limit).map(\.id)
    }

    @Test func includesRecentFriendAndFriendOfFriendListings() {
        let homes = [
            makeHome(id: "friendNew", hostUserID: "friend", createdAt: daysAgo(1)),
            makeHome(id: "fofNew", hostUserID: "stranger", visibility: .friendsOfFriends,
                     allowedViewerIDs: [me], createdAt: daysAgo(2))
        ]
        #expect(rail(homes) == ["friendNew", "fofNew"])
    }

    @Test func excludesYourOwnListingsStrangersAndStaleOnes() {
        let homes = [
            makeHome(id: "mine", hostUserID: me, createdAt: daysAgo(1)),
            makeHome(id: "stranger", hostUserID: "stranger", visibility: .everyone, createdAt: daysAgo(1)),
            makeHome(id: "stale", hostUserID: "friend", createdAt: daysAgo(15))
        ]
        #expect(rail(homes).isEmpty)
    }

    /// A listing exactly at the window's edge is still new; one second past it is
    /// not. Pinned because the boundary is the whole definition of the section.
    @Test func windowBoundaryIsInclusive() {
        let onEdge = makeHome(id: "onEdge", hostUserID: "friend", createdAt: now.addingTimeInterval(-FeedSections.newWindow))
        let pastEdge = makeHome(id: "pastEdge", hostUserID: "friend", createdAt: now.addingTimeInterval(-FeedSections.newWindow - 1))
        #expect(rail([onEdge, pastEdge]) == ["onEdge"])
    }

    /// `createdAt` is the section's only evidence of recency. Without it, a
    /// listing cannot claim to be new.
    @Test func listingWithoutCreatedAtIsExcluded() {
        let undated = makeHome(id: "undated", hostUserID: "friend")
        #expect(rail([undated]).isEmpty)
    }

    @Test func ordersNewestFirstAndBreaksTiesByIDForATotalOrder() {
        let homes = [
            makeHome(id: "old", hostUserID: "friend", createdAt: daysAgo(5)),
            makeHome(id: "b", hostUserID: "friend", createdAt: daysAgo(1)),
            makeHome(id: "a", hostUserID: "friend", createdAt: daysAgo(1))
        ]
        #expect(rail(homes) == ["a", "b", "old"])
    }

    @Test func capsAtTheLimit() {
        let homes = (0..<15).map { makeHome(id: "h\($0)", hostUserID: "friend", createdAt: daysAgo(1)) }
        #expect(rail(homes, limit: 3).count == 3)
    }
}

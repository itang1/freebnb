//
//  FeedOrderingTests.swift
//  freebnbTests
//
//  Covers HomeStore's feed derivation: block filtering, friends-only
//  visibility, and — the reason this file exists — that the ordering is a total
//  order. Swift's sort is not stable, so a comparator that reports "equal" for
//  distinct rows lets them reshuffle between recomputes (L9).
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
    home.createdAt = createdAt
    return home
}

struct FeedOrderingTests {
    private let me = "me"

    @Test func friendsSortBeforeOwnListingsAndStrangers() {
        let listings = [
            makeHome(id: "c", hostUserID: "stranger"),
            makeHome(id: "b", hostUserID: me),
            makeHome(id: "a", hostUserID: "friend")
        ]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: ["friend"], blockedIDs: []
        )

        #expect(feed.map(\.id) == ["a", "b", "c"])
    }

    /// The bug: equal-ranked rows must break ties on a stable key, or an
    /// unstable sort reorders them on every recompute.
    @Test func orderingIsATotalOrderAcrossPermutations() {
        // Six same-rank strangers: nothing but the id tiebreak separates them.
        let ids = ["f", "d", "a", "e", "b", "c"]
        let listings = ids.map { makeHome(id: $0, hostUserID: "stranger-\($0)") }

        let expected = ["a", "b", "c", "d", "e", "f"]
        for _ in 0..<200 {
            let feed = HomeStore.feed(
                from: listings.shuffled(), myID: me, friendIDs: [], blockedIDs: []
            )
            #expect(feed.map(\.id) == expected)
        }
    }

    @Test func tiesWithinTheFriendBucketAlsoBreakDeterministically() {
        let listings = [
            makeHome(id: "z", hostUserID: "friend1"),
            makeHome(id: "y", hostUserID: "friend2"),
            makeHome(id: "x", hostUserID: "stranger")
        ]

        let feed = HomeStore.feed(
            from: listings.shuffled(), myID: me, friendIDs: ["friend1", "friend2"], blockedIDs: []
        )

        // Both friends outrank the stranger; ids break the tie between them.
        #expect(feed.map(\.id) == ["y", "z", "x"])
    }

    /// Within a rank bucket, newer listings sort ahead of older ones (L3).
    @Test func newerListingsSortFirstWithinARank() {
        let older = makeHome(id: "a", hostUserID: "s1", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeHome(id: "b", hostUserID: "s2", createdAt: Date(timeIntervalSince1970: 2_000))

        let feed = HomeStore.feed(
            from: [older, newer], myID: me, friendIDs: [], blockedIDs: []
        )

        // Both are same-rank strangers; recency puts the newer one first even
        // though its id ("b") sorts after the older one's ("a").
        #expect(feed.map(\.id) == ["b", "a"])
    }

    /// Recency wins over the friend-first grouping only within a bucket, never
    /// across buckets: a newer stranger still sorts below an older friend.
    @Test func recencyDoesNotOutrankFriendGrouping() {
        let newerStranger = makeHome(id: "a", hostUserID: "stranger", createdAt: Date(timeIntervalSince1970: 2_000))
        let olderFriend = makeHome(id: "b", hostUserID: "friend", createdAt: Date(timeIntervalSince1970: 1_000))

        let feed = HomeStore.feed(
            from: [newerStranger, olderFriend], myID: me, friendIDs: ["friend"], blockedIDs: []
        )

        #expect(feed.map(\.id) == ["b", "a"])
    }

    @Test func blockedHostsAreRemoved() {
        let listings = [
            makeHome(id: "a", hostUserID: "blocked"),
            makeHome(id: "b", hostUserID: "stranger")
        ]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: [], blockedIDs: ["blocked"]
        )

        #expect(feed.map(\.id) == ["b"])
    }

    @Test func friendsOnlyListingsAreHiddenFromNonFriends() {
        let listings = [
            makeHome(id: "a", hostUserID: "stranger", visibility: .friendsOnly),
            makeHome(id: "b", hostUserID: "friend", visibility: .friendsOnly),
            makeHome(id: "c", hostUserID: me, visibility: .friendsOnly),
            makeHome(id: "d", hostUserID: "stranger", visibility: .everyone)
        ]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: ["friend"], blockedIDs: []
        )

        // "a" is a stranger's friends-only listing; the rest are visible.
        #expect(feed.map(\.id) == ["b", "c", "d"])
    }

    /// Nil visibility is legacy data and must be treated as `.everyone`.
    @Test func listingsWithNoVisibilityFieldAreVisibleToEveryone() {
        let listings = [makeHome(id: "a", hostUserID: "stranger", visibility: nil)]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: [], blockedIDs: []
        )

        #expect(feed.map(\.id) == ["a"])
    }
}

//
//  NetworkReachTests.swift
//  freebnbTests
//
//  Covers the pure derivation behind the "Your network" section (feature 34). The
//  cases that matter are the ones where it must not over-claim: your own listings
//  and public strangers don't count, and a friend-of-a-friend home is counted but
//  never pinned to a name it can't actually know.
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
    allowedViewerIDs: [String]? = nil
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
    return home
}

struct NetworkReachTests {
    private let me = "me"
    private let friends: Set<String> = ["priya", "sam"]
    private let names: [String: String] = ["priya": "Priya", "sam": "Sam"]

    private func compute(_ homes: [Home]) -> NetworkReach {
        NetworkReach.compute(
            homes: homes,
            myID: me,
            friendIDs: friends,
            displayName: { names[$0] }
        )
    }

    @Test func countsHomesPerFriendHost() {
        let reach = compute([
            makeHome(id: "1", hostUserID: "priya"),
            makeHome(id: "2", hostUserID: "priya"),
            makeHome(id: "3", hostUserID: "sam"),
        ])
        #expect(reach.hosts.count == 2)
        #expect(reach.hosts.first?.friendID == "priya")
        #expect(reach.hosts.first?.displayName == "Priya")
        #expect(reach.hosts.first?.homeCount == 2)
        #expect(reach.totalHomes == 3)
    }

    @Test func sortsMostHomesFirst() {
        let reach = compute([
            makeHome(id: "1", hostUserID: "sam"),
            makeHome(id: "2", hostUserID: "priya"),
            makeHome(id: "3", hostUserID: "priya"),
        ])
        #expect(reach.hosts.map(\.friendID) == ["priya", "sam"])
    }

    @Test func excludesYourOwnAndStrangers() {
        let reach = compute([
            makeHome(id: "mine", hostUserID: me),
            makeHome(id: "stranger", hostUserID: "nobody", visibility: .everyone),
            makeHome(id: "friend", hostUserID: "priya"),
        ])
        #expect(reach.totalHomes == 1)
        #expect(reach.hosts.map(\.friendID) == ["priya"])
        #expect(reach.extendedCount == 0)
    }

    /// A friend-of-a-friend listing counts toward reach but is never attributed to
    /// a friend by name — that link is unknowable client-side.
    @Test func friendOfFriendCountsButIsNotNamed() {
        let reach = compute([
            makeHome(
                id: "fof",
                hostUserID: "stranger",
                visibility: .friendsOfFriends,
                allowedViewerIDs: [me]
            ),
        ])
        #expect(reach.hosts.isEmpty)
        #expect(reach.extendedCount == 1)
        #expect(reach.totalHomes == 1)
    }

    @Test func fallsBackWhenNameUnresolved() {
        let reach = NetworkReach.compute(
            homes: [makeHome(id: "1", hostUserID: "priya")],
            myID: me,
            friendIDs: friends,
            displayName: { _ in nil }
        )
        #expect(reach.hosts.first?.displayName == "FreeBNB User")
    }

    @Test func signedOutViewerReachesNothing() {
        let reach = NetworkReach.compute(
            homes: [makeHome(id: "1", hostUserID: "priya")],
            myID: "",
            friendIDs: friends,
            displayName: { names[$0] }
        )
        #expect(reach.isEmpty)
    }

    @Test func emptyWhenNoNetworkHomes() {
        #expect(compute([]).isEmpty)
    }
}

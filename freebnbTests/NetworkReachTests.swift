//
//  NetworkReachTests.swift
//  freebnbTests
//
//  Covers the pure derivation behind the "Your network" section (feature 34). The
//  cases that matter are the ones where it must not over-claim: your own listings
//  don't count, and neither does a host the client can't verify as a friend.
//

import Foundation
import Testing
@testable import freebnb


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
            HomeFixture.make(id: "1", hostUserID: "priya"),
            HomeFixture.make(id: "2", hostUserID: "priya"),
            HomeFixture.make(id: "3", hostUserID: "sam"),
        ])
        #expect(reach.hosts.count == 2)
        #expect(reach.hosts.first?.friendID == "priya")
        #expect(reach.hosts.first?.displayName == "Priya")
        #expect(reach.hosts.first?.homeCount == 2)
        #expect(reach.totalHomes == 3)
    }

    @Test func sortsMostHomesFirst() {
        let reach = compute([
            HomeFixture.make(id: "1", hostUserID: "sam"),
            HomeFixture.make(id: "2", hostUserID: "priya"),
            HomeFixture.make(id: "3", hostUserID: "priya"),
        ])
        #expect(reach.hosts.map(\.friendID) == ["priya", "sam"])
    }

    @Test func excludesYourOwnAndUnverifiableHosts() {
        let reach = compute([
            HomeFixture.make(id: "mine", hostUserID: me),
            // A stale ACL entry from an ended friendship: reachable, but not a
            // connection the client can attribute.
            HomeFixture.make(id: "stranger", hostUserID: "nobody", allowedViewerIDs: [me]),
            HomeFixture.make(id: "friend", hostUserID: "priya"),
        ])
        #expect(reach.totalHomes == 1)
        #expect(reach.hosts.map(\.friendID) == ["priya"])
    }

    @Test func fallsBackWhenNameUnresolved() {
        let reach = NetworkReach.compute(
            homes: [HomeFixture.make(id: "1", hostUserID: "priya")],
            myID: me,
            friendIDs: friends,
            displayName: { _ in nil }
        )
        #expect(reach.hosts.first?.displayName == "FreeBNB User")
    }

    @Test func signedOutViewerReachesNothing() {
        let reach = NetworkReach.compute(
            homes: [HomeFixture.make(id: "1", hostUserID: "priya")],
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

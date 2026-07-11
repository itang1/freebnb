//
//  CoHostTests.swift
//  freebnbTests
//
//  Co-hosts (feature 14). The security boundary is proven against the emulator in
//  rules-tests/cohosts.test.mjs; this covers the client's side of the same
//  contract — the model's host-vs-manager distinction, back-compatible decoding,
//  and the HomeStore guards that keep the app from *attempting* a write the rules
//  would reject (notably: never batch two additions, because a loop-free rule can
//  only vet one).
//

import Foundation
import Testing
@testable import freebnb

struct CoHostModelTests {
    @Test func hostManagesAndHostsTheirListing() {
        let home = HomeFixture.make(hostUserID: "host")
        #expect(home.isHostedBy("host"))
        #expect(home.isManagedBy("host"))
    }

    /// The load-bearing distinction: a co-host manages the listing but does not
    /// host it. Everything host-only keys off `isHostedBy`.
    @Test func coHostManagesButDoesNotHost() {
        let home = HomeFixture.make(hostUserID: "host", coHosts: ["cohost"])
        #expect(home.isManagedBy("cohost"))
        #expect(!home.isHostedBy("cohost"))
    }

    @Test func strangerNeitherHostsNorManages() {
        let home = HomeFixture.make(hostUserID: "host", coHosts: ["cohost"])
        #expect(!home.isManagedBy("stranger"))
        #expect(!home.isHostedBy("stranger"))
    }

    /// An empty user id is a signed-out viewer, who manages nothing — even a
    /// listing that somehow carried "" in its roster.
    @Test func emptyUserIDManagesNothing() {
        let home = HomeFixture.make(hostUserID: "", coHosts: [""])
        #expect(!home.isManagedBy(""))
        #expect(!home.isHostedBy(""))
    }

    @Test func coHostsViewIsEmptyWhenAbsent() {
        #expect(HomeFixture.make().coHosts.isEmpty)
        #expect(HomeFixture.make(coHosts: ["a", "b"]).coHosts == ["a", "b"])
    }

    /// A listing written before feature 14 has no `coHostUserIDs`; it must still
    /// decode, or it vanishes from the feed (A5).
    @Test func listingWithoutRosterDecodesWithNoCoHosts() throws {
        let json = """
        {
          "hostUserID": "host", "hostName": "Host",
          "address": { "city": "Town", "state": "CA", "zip": "00000" },
          "sleeping": { "numGuestRooms": 1, "arrangements": { "bed": 1 } },
          "guestPolicy": { "maxGuests": 2, "maxStayDays": 7, "kidsAllowed": true, "guestPetsAllowed": false },
          "amenities": {
            "hasAC": false, "hasHeating": false, "hasKitchen": false, "hasFridgeSpace": false,
            "hasMicrowave": false, "hasTV": false, "hasWifi": false,
            "hasPrivateGuestBathroom": false, "hostHasPets": false, "parkingDetails": "",
            "hasInUnitLaundry": false, "hasCoinLaundryNearby": false,
            "providesPillows": false, "providesBlankets": false, "providesTowels": false,
            "providesToiletries": false, "foodProvision": "none"
          }
        }
        """
        let home = try JSONDecoder().decode(Home.self, from: Data(json.utf8))
        #expect(home.coHostUserIDs == nil)
        #expect(home.coHosts.isEmpty)
    }

    @Test func rosterSurvivesAnEncodeDecodeRoundTrip() throws {
        var home = HomeFixture.make(coHosts: ["a", "b"])
        home.id = "home-x"
        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))
        #expect(restored.coHostUserIDs == ["a", "b"])
    }
}

@MainActor
struct CoHostStoreTests {
    private func store(_ homes: [Home]) -> (HomeStore, InMemoryHomesRepository) {
        let repo = InMemoryHomesRepository(homes: homes)
        return (HomeStore(repository: repo), repo)
    }

    private func fetch(_ repo: InMemoryHomesRepository, id: String) async throws -> Home {
        let all = try await repo.fetchVisibleListings(viewerID: "host", after: nil, limit: 50)
        return try #require(all.first { $0.id == id })
    }

    @Test func addCoHostAppendsOneToTheRoster() async throws {
        let home = HomeFixture.make()
        let (store, repo) = store([home])
        try await store.addCoHost("friend", to: home, hostUserID: "host")
        #expect(try await fetch(repo, id: home.id).coHosts == ["friend"])
    }

    @Test func addingAnExistingCoHostIsANoOp() async throws {
        let home = HomeFixture.make(coHosts: ["friend"])
        let (store, repo) = store([home])
        try await store.addCoHost("friend", to: home, hostUserID: "host")
        #expect(try await fetch(repo, id: home.id).coHosts == ["friend"])
    }

    /// A non-host must not even attempt a roster write; the rules would reject it,
    /// but the app should not offer it.
    @Test func onlyTheHostMayAddCoHosts() async throws {
        let home = HomeFixture.make(coHosts: ["cohost"])
        let (store, _) = store([home])
        await #expect(throws: CoHostError.self) {
            try await store.addCoHost("stranger", to: home, hostUserID: "cohost")
        }
    }

    @Test func theHostCannotCoHostTheirOwnListing() async throws {
        let home = HomeFixture.make()
        let (store, _) = store([home])
        await #expect(throws: CoHostError.self) {
            try await store.addCoHost("host", to: home, hostUserID: "host")
        }
    }

    @Test func theRosterCannotExceedTheCap() async throws {
        let full = Array(0..<Home.maxCoHosts).map { "c\($0)" }
        let home = HomeFixture.make(coHosts: full)
        let (store, _) = store([home])
        await #expect(throws: CoHostError.self) {
            try await store.addCoHost("oneMore", to: home, hostUserID: "host")
        }
    }

    @Test func removeCoHostDropsThemFromTheRoster() async throws {
        let home = HomeFixture.make(coHosts: ["a", "b"])
        let (store, repo) = store([home])
        try await store.removeCoHost("a", from: home, hostUserID: "host")
        #expect(try await fetch(repo, id: home.id).coHosts == ["b"])
    }

    @Test func onlyTheHostMayRemoveCoHosts() async throws {
        let home = HomeFixture.make(coHosts: ["a", "b"])
        let (store, _) = store([home])
        await #expect(throws: CoHostError.self) {
            try await store.removeCoHost("a", from: home, hostUserID: "a")
        }
    }
}

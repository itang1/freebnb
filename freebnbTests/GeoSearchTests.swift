//
//  GeoSearchTests.swift
//  freebnbTests
//
//  Covers the radius filter and the nearest-first sort (feature 11). The cases
//  that matter are the ones about listings with no coordinate: a radius filter is
//  a promise about distance, and a listing that cannot prove it is nearby must
//  not be admitted by one — while an unfiltered sort should still rank it rather
//  than hide it.
//

import Foundation
import Testing
@testable import freebnb


// Real places, so the asserted distances are checkable against a map.
private let sanFrancisco = Coordinate(latitude: 37.7749, longitude: -122.4194)
private let oakland = Coordinate(latitude: 37.8044, longitude: -122.2712)      // ~8.3 mi from SF
private let sanJose = Coordinate(latitude: 37.3382, longitude: -121.8863)      // ~42 mi from SF
private let portland = Coordinate(latitude: 45.5152, longitude: -122.6784)     // ~535 mi from SF

struct GeoDistanceTests {
    @Test func distanceIsSymmetricAndZeroAtThePoint() {
        #expect(Geo.distanceMiles(from: sanFrancisco, to: sanFrancisco) == 0)
        let there = Geo.distanceMiles(from: sanFrancisco, to: oakland)
        let back = Geo.distanceMiles(from: oakland, to: sanFrancisco)
        // CLLocation's ellipsoidal geodesic isn't bit-exact symmetric; sub-meter
        // drift between directions is expected, not a bug.
        #expect(abs(there - back) < 0.01)
    }

    @Test func knownDistancesLandInTheRightNeighbourhood() {
        #expect((7.5...9.5).contains(Geo.distanceMiles(from: sanFrancisco, to: oakland)))
        #expect((40.0...45.0).contains(Geo.distanceMiles(from: sanFrancisco, to: sanJose)))
        #expect((525.0...545.0).contains(Geo.distanceMiles(from: sanFrancisco, to: portland)))
    }

    /// Under a mile the integer form would read "0 mi away", which is both wrong
    /// and more precise than the blurred coordinate can support.
    @Test func distanceTextKeepsADecimalOnlyBelowTenMiles() {
        #expect(Geo.distanceText(0.42) == "0.4 mi away")
        #expect(Geo.distanceText(9.94) == "9.9 mi away")
        #expect(Geo.distanceText(12.4) == "12 mi away")
        #expect(Geo.distanceText(12.6) == "13 mi away")
    }
}

struct GeoScopeTests {
    @Test func noRadiusAdmitsEverythingIncludingTheUnlocatable() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: nil)
        #expect(scope.contains(HomeFixture.make(id: "far", coordinate: portland)))
        #expect(scope.contains(HomeFixture.make(id: "nowhere")))
    }

    @Test func radiusAdmitsOnlyListingsInsideIt() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: 25)
        #expect(scope.contains(HomeFixture.make(id: "oakland", coordinate: oakland)))
        #expect(!scope.contains(HomeFixture.make(id: "sanJose", coordinate: sanJose)))
    }

    /// A listing with no coordinate cannot prove it is nearby, so a radius filter
    /// must drop it rather than quietly admit the one listing the user can't check.
    @Test func radiusExcludesListingsWithNoCoordinate() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: 25)
        #expect(!scope.contains(HomeFixture.make(id: "nowhere")))
    }

    @Test func distanceIsNilForListingsWithNoCoordinate() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: nil)
        #expect(scope.distance(to: HomeFixture.make(id: "nowhere")) == nil)
        #expect(scope.distance(to: HomeFixture.make(id: "oakland", coordinate: oakland)) != nil)
    }
}

struct FilterAndSortGeoTests {
    private func ids(
        _ homes: [Home],
        query: String = "",
        sort: SortOption = .default,
        scope: GeoScope? = nil
    ) -> [String] {
        filterAndSort(
            homes,
            query: query,
            filters: [],
            savedIDs: [],
            savedOnly: false,
            sort: sort,
            scope: scope
        ).map(\.id)
    }

    private var homes: [Home] {
        [
            HomeFixture.make(id: "portland", city: "Portland", coordinate: portland),
            HomeFixture.make(id: "sanJose", city: "San Jose", coordinate: sanJose),
            HomeFixture.make(id: "oakland", city: "Oakland", coordinate: oakland)
        ]
    }

    @Test func nearestSortsClosestFirst() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: nil)
        #expect(ids(homes, sort: .nearest, scope: scope) == ["oakland", "sanJose", "portland"])
    }

    /// Nothing to be near: the sort must leave the feed's own ordering alone
    /// rather than shuffle it.
    @Test func nearestWithoutAScopeIsANoOp() {
        #expect(ids(homes, sort: .nearest) == ["portland", "sanJose", "oakland"])
    }

    /// Unlocatable listings rank last but survive, since no radius was promised.
    @Test func nearestRanksListingsWithNoCoordinateLast() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: nil)
        let withUnlocatable = homes + [HomeFixture.make(id: "nowhere")]
        #expect(ids(withUnlocatable, sort: .nearest, scope: scope).last == "nowhere")
    }

    /// Equidistant rows must hold a stable order across recomputes; Swift's sort
    /// is not stable, so the comparator has to break the tie itself.
    @Test func equidistantListingsAreOrderedByIDForATotalOrder() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: nil)
        let tied = [
            HomeFixture.make(id: "b", coordinate: oakland),
            HomeFixture.make(id: "a", coordinate: oakland),
            HomeFixture.make(id: "c", coordinate: oakland)
        ]
        #expect(ids(tied, sort: .nearest, scope: scope) == ["a", "b", "c"])
    }

    @Test func radiusNarrowsTheFeed() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: 25)
        #expect(ids(homes, sort: .nearest, scope: scope) == ["oakland"])
    }

    /// The radius composes with the text query rather than replacing it.
    @Test func radiusAndTextQueryBothApply() {
        let scope = GeoScope(center: sanFrancisco, radiusMiles: 100)
        #expect(ids(homes, query: "oakland", scope: scope) == ["oakland"])
        #expect(ids(homes, query: "portland", scope: scope).isEmpty)
    }
}

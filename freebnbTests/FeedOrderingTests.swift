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


struct FeedOrderingTests {
    private let me = "me"

    @Test func friendsSortBeforeOwnListingsAndStrangers() {
        let listings = [
            HomeFixture.make(id: "c", hostUserID: "stranger"),
            HomeFixture.make(id: "b", hostUserID: me),
            HomeFixture.make(id: "a", hostUserID: "friend")
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
        let listings = ids.map { HomeFixture.make(id: $0, hostUserID: "stranger-\($0)") }

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
            HomeFixture.make(id: "z", hostUserID: "friend1"),
            HomeFixture.make(id: "y", hostUserID: "friend2"),
            HomeFixture.make(id: "x", hostUserID: "stranger")
        ]

        let feed = HomeStore.feed(
            from: listings.shuffled(), myID: me, friendIDs: ["friend1", "friend2"], blockedIDs: []
        )

        // Both friends outrank the stranger; ids break the tie between them.
        #expect(feed.map(\.id) == ["y", "z", "x"])
    }

    /// Within a rank bucket, newer listings sort ahead of older ones (L3).
    @Test func newerListingsSortFirstWithinARank() {
        let older = HomeFixture.make(id: "a", hostUserID: "s1", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = HomeFixture.make(id: "b", hostUserID: "s2", createdAt: Date(timeIntervalSince1970: 2_000))

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
        let newerStranger = HomeFixture.make(id: "a", hostUserID: "stranger", createdAt: Date(timeIntervalSince1970: 2_000))
        let olderFriend = HomeFixture.make(id: "b", hostUserID: "friend", createdAt: Date(timeIntervalSince1970: 1_000))

        let feed = HomeStore.feed(
            from: [newerStranger, olderFriend], myID: me, friendIDs: ["friend"], blockedIDs: []
        )

        #expect(feed.map(\.id) == ["b", "a"])
    }

    @Test func blockedHostsAreRemoved() {
        let listings = [
            HomeFixture.make(id: "a", hostUserID: "blocked"),
            HomeFixture.make(id: "b", hostUserID: "stranger")
        ]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: [], blockedIDs: ["blocked"]
        )

        #expect(feed.map(\.id) == ["b"])
    }

    @Test func friendsOnlyListingsAreHiddenFromNonFriends() {
        let listings = [
            HomeFixture.make(id: "a", hostUserID: "stranger", visibility: .friendsOnly),
            HomeFixture.make(id: "b", hostUserID: "friend", visibility: .friendsOnly),
            HomeFixture.make(id: "c", hostUserID: me, visibility: .friendsOnly),
            HomeFixture.make(id: "d", hostUserID: "stranger", visibility: .everyone)
        ]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: ["friend"], blockedIDs: []
        )

        // "a" is a stranger's friends-only listing; the rest are visible.
        #expect(feed.map(\.id) == ["b", "c", "d"])
    }

    /// Nil visibility is legacy data and must be treated as `.everyone`.
    @Test func listingsWithNoVisibilityFieldAreVisibleToEveryone() {
        let listings = [HomeFixture.make(id: "a", hostUserID: "stranger", visibility: nil)]

        let feed = HomeStore.feed(
            from: listings, myID: me, friendIDs: [], blockedIDs: []
        )

        #expect(feed.map(\.id) == ["a"])
    }
}

/// Covers `FeedSearchPaging`, the rule that decides whether a search or filter
/// keeps pulling pages. Search runs client-side over fetched pages, so without
/// this the feed reports "no homes found" for matches sitting on a page it never
/// requested (L3).
struct FeedSearchPagingTests {
    private func paging(
        isNarrowing: Bool = true,
        canLoadMore: Bool = true,
        isLoadingMore: Bool = false,
        hasError: Bool = false,
        pagesLoaded: Int = 0,
        maxPages: Int = 20
    ) -> FeedSearchPaging {
        FeedSearchPaging(
            isNarrowing: isNarrowing,
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            hasError: hasError,
            pagesLoaded: pagesLoaded,
            maxPages: maxPages
        )
    }

    @Test func anActiveQueryWithUnfetchedPagesKeepsPaging() {
        #expect(paging().shouldFetchNextPage)
        #expect(paging().isSearchingRemainingPages)
    }

    /// The whole point: browsing the unfiltered feed must still page lazily off
    /// the scroll sentinel, not eagerly download everything.
    @Test func anIdleFeedDoesNotPage() {
        #expect(!paging(isNarrowing: false).shouldFetchNextPage)
        #expect(!paging(isNarrowing: false).isSearchingRemainingPages)
    }

    @Test func anExhaustedFeedStopsAndReleasesTheEmptyState() {
        let exhausted = paging(canLoadMore: false)
        #expect(!exhausted.shouldFetchNextPage)
        // No pages left to search, so "no homes found" is now the truth.
        #expect(!exhausted.isSearchingRemainingPages)
    }

    @Test func aFetchInFlightIsNotDoubleRequested() {
        let inFlight = paging(isLoadingMore: true)
        #expect(!inFlight.shouldFetchNextPage)
        // Still searching, though — the empty state stays suppressed.
        #expect(inFlight.isSearchingRemainingPages)
    }

    /// A failed page leaves `canLoadMore` set; retrying it up to the cap would
    /// hammer a broken query.
    @Test func aFailedPageStopsTheLoop() {
        #expect(!paging(hasError: true).shouldFetchNextPage)
    }

    @Test func thePageBudgetBoundsTheLoop() {
        #expect(paging(pagesLoaded: 19, maxPages: 20).shouldFetchNextPage)
        let capped = paging(pagesLoaded: 20, maxPages: 20)
        #expect(!capped.shouldFetchNextPage)
        // Cap reached with pages still unread: stop paging, and let the empty
        // state say so rather than spinning forever.
        #expect(!capped.isSearchingRemainingPages)
    }
}

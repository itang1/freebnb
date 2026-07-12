//
//  FeedSectionsTests.swift
//  freebnbTests
//
//  Covers the pure derivation behind the feed's explanatory chips (feature 18).
//  The chip makes a claim about who knows whom, so the cases that matter most
//  here are the ones where it must stay silent.
//

import Foundation
import Testing
@testable import freebnb


struct FeedReasonTests {
    private let me = "me"
    private let friends: Set<String> = ["friend"]

    @Test func ownListingIsLabelledAsYours() {
        let home = HomeFixture.make(id: "a", hostUserID: me)
        #expect(FeedSections.reason(for: home, myID: me, friendIDs: friends) == .yourListing)
    }

    @Test func friendsListingIsLabelledAsFriend() {
        let home = HomeFixture.make(id: "a", hostUserID: "friend")
        #expect(FeedSections.reason(for: home, myID: me, friendIDs: friends) == .friend)
    }

    /// A host who isn't a verified friend gets no chip, even when the ACL still
    /// names the viewer (a friendship that ended since the listing was written):
    /// a wrong chip is a false statement about who knows whom.
    @Test func unverifiableConnectionStaysSilent() {
        let staleACL = HomeFixture.make(id: "a", hostUserID: "stranger", allowedViewerIDs: [me])
        #expect(FeedSections.reason(for: staleACL, myID: me, friendIDs: friends) == nil)

        let noACL = HomeFixture.make(id: "b", hostUserID: "stranger")
        #expect(FeedSections.reason(for: noACL, myID: me, friendIDs: friends) == nil)
    }

    /// A signed-out browser has no network, so nothing about the graph is true of
    /// them — including, importantly, that an ACL entry for "" means anything.
    @Test func signedOutViewerNeverEarnsAChip() {
        let ownedByEmptyString = HomeFixture.make(id: "a", hostUserID: "", allowedViewerIDs: [""])
        #expect(FeedSections.reason(for: ownedByEmptyString, myID: "", friendIDs: []) == nil)
    }
}

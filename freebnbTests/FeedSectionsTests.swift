//
//  FeedSectionsTests.swift
//  freebnbTests
//
//  Covers the derivation behind the feed's explanatory chips; the chip claims who knows whom, so the key cases are where it stays silent.
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

    /// A host who isn't a verified friend gets no chip even if the ACL names the viewer (an ended friendship); a wrong chip is a false statement.
    @Test func unverifiableConnectionStaysSilent() {
        let staleACL = HomeFixture.make(id: "a", hostUserID: "stranger", allowedViewerIDs: [me])
        #expect(FeedSections.reason(for: staleACL, myID: me, friendIDs: friends) == nil)

        let noACL = HomeFixture.make(id: "b", hostUserID: "stranger")
        #expect(FeedSections.reason(for: noACL, myID: me, friendIDs: friends) == nil)
    }

    /// A signed-out browser has no network, so an ACL entry for "" means nothing.
    @Test func signedOutViewerNeverEarnsAChip() {
        let ownedByEmptyString = HomeFixture.make(id: "a", hostUserID: "", allowedViewerIDs: [""])
        #expect(FeedSections.reason(for: ownedByEmptyString, myID: "", friendIDs: []) == nil)
    }
}

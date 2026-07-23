//
//  InviteLinkTests.swift
//  freebnbTests
//
//  The invite link is the only bridge between an invited person and the app,
//  which is empty until they connect to the friend who invited them. These
//  cover the round trip (build a link, parse it back) and the two things the
//  link must never do: name nobody when it can, or act on its own.
//

import Testing
import Foundation
@testable import freebnb

@MainActor
struct InviteLinkTests {
    @Test func inviteURLCarriesTheSender() {
        let url = InviteCopy.inviteURL(senderID: "uid-maya")
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: "uid-maya"))
    }

    @Test func inviteURLWithoutASenderStillRoutes() {
        let url = InviteCopy.inviteURL()
        #expect(url.absoluteString == "freebnb://invite")
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: nil))
    }

    /// An older link, or one built before the profile loaded, must land on the
    /// Friends tab rather than nowhere.
    @Test func emptySenderReadsAsAbsent() {
        let url = URL(string: "freebnb://invite?from=")!
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: nil))
    }

    @Test func staysLinkIsUnchanged() {
        #expect(DeepLinkRouter.route(for: URL(string: "freebnb://stays")!) == .stays)
    }

    @Test func foreignAndUnknownURLsAreIgnored() {
        #expect(DeepLinkRouter.route(for: URL(string: "https://example.com/invite?from=x")!) == nil)
        #expect(DeepLinkRouter.route(for: URL(string: "freebnb://elsewhere")!) == nil)
    }

    /// Following an invite navigates and nothing more: no edge, no write. The
    /// recipient still has to tap Add, and the sender still has to accept.
    @Test func handlingAnInviteOnlyNavigates() {
        let router = DeepLinkRouter()
        router.handle(.invite(senderID: "uid-maya"))
        #expect(router.pendingInviterID == "uid-maya")
        #expect(router.pendingFriendsTab)
        #expect(router.pendingStayEvent == false)
        #expect(router.pendingConversationUserID == nil)
    }

    @Test func vouchCopyPointsAtTheLinkWhenItNamesTheSender() {
        let message = InviteCopy.vouch(inviterName: "Maya", senderID: "uid-maya")
        #expect(message.hasPrefix("It's Maya. "))
        #expect(message.contains("freebnb://invite?from=uid-maya"))
        #expect(message.contains("open the app on my profile"))
    }

    /// Without an ID there is no card to open onto, so the copy has to fall back
    /// to asking them to search, and it must still name who to search for.
    @Test func vouchCopyFallsBackToSearchWithoutASender() {
        let message = InviteCopy.vouch(inviterName: "Maya")
        #expect(message.contains("search for Maya"))
        #expect(message.contains("freebnb://invite"))
        #expect(!message.contains("?from="))
    }

    @Test func tripAndHostInvitesCarryTheSenderToo() {
        let trip = InviteCopy.tripIntent(city: "Austin", inviterName: "Maya", senderID: "uid-maya")
        #expect(trip.contains("Austin"))
        #expect(trip.contains("freebnb://invite?from=uid-maya"))

        let host = InviteCopy.askToHost(inviterName: "Maya", senderID: "uid-maya")
        #expect(host.contains("freebnb://invite?from=uid-maya"))
    }
}

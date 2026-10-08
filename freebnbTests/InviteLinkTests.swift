//
//  InviteLinkTests.swift
//  freebnbTests
//
//  The invite link bridges an invited person to the app. These cover the build/parse round
//  trip and what the link must never do: name nobody when it can, or act on its own.
//

import Testing
import Foundation
@testable import freebnb

@MainActor
struct InviteLinkTests {
    /// An invite is an https Universal Link so it resolves on a phone without the app, unlike the custom scheme.
    @Test func inviteURLIsAUniversalLinkCarryingTheSender() {
        let url = InviteCopy.inviteURL(senderID: "uid-maya")
        #expect(url.scheme == "https")
        #expect(url.absoluteString == "https://\(InviteCopy.webHost)\(InviteCopy.webPath)?from=uid-maya")
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: "uid-maya"))
    }

    @Test func inviteURLWithoutASenderStillRoutes() {
        let url = InviteCopy.inviteURL()
        #expect(url.absoluteString == "https://\(InviteCopy.webHost)\(InviteCopy.webPath)")
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: nil))
    }

    /// A browser or share sheet may add the trailing slash; it is the same link.
    @Test func theTrailingSlashFormRoutesTheSameWay() {
        let url = URL(string: "https://\(InviteCopy.webHost)\(InviteCopy.webPath)/?from=uid-maya")!
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: "uid-maya"))
    }

    /// Links sent before the switch are still out there in people's messages.
    @Test func theOldCustomSchemeInviteStillWorks() {
        #expect(
            DeepLinkRouter.route(for: URL(string: "freebnb://invite?from=uid-maya")!)
                == .invite(senderID: "uid-maya")
        )
        #expect(DeepLinkRouter.route(for: URL(string: "freebnb://invite")!) == .invite(senderID: nil))
        // The web page hands the app this form when the Universal Link didn't open it, so it must round-trip.
        #expect(
            DeepLinkRouter.route(for: InviteCopy.customSchemeInviteURL(senderID: "uid-maya"))
                == .invite(senderID: "uid-maya")
        )
    }

    /// An older link, or one built before the profile loaded, must land on the
    /// Friends tab rather than nowhere.
    @Test func emptySenderReadsAsAbsent() {
        let url = URL(string: "freebnb://invite?from=")!
        #expect(DeepLinkRouter.route(for: url) == .invite(senderID: nil))
        let webURL = URL(string: "https://\(InviteCopy.webHost)\(InviteCopy.webPath)?from=")!
        #expect(DeepLinkRouter.route(for: webURL) == .invite(senderID: nil))
    }

    @Test func staysLinkIsUnchanged() {
        #expect(DeepLinkRouter.route(for: URL(string: "freebnb://stays")!) == .stays)
    }

    /// Host and path are checked, not trusted: a pasted string can arrive, and a look-alike host mustn't count as an invite.
    @Test func foreignAndUnknownURLsAreIgnored() {
        #expect(DeepLinkRouter.route(for: URL(string: "https://example.com/i?from=x")!) == nil)
        #expect(DeepLinkRouter.route(for: URL(string: "https://\(InviteCopy.webHost)/elsewhere?from=x")!) == nil)
        #expect(DeepLinkRouter.route(for: URL(string: "https://\(InviteCopy.webHost)/i/deeper?from=x")!) == nil)
        #expect(DeepLinkRouter.route(for: URL(string: "freebnb://elsewhere")!) == nil)
    }

    /// Following an invite only navigates: no edge, no write; the recipient still taps Add and the sender accepts.
    @Test func handlingAnInviteOnlyNavigates() {
        let router = DeepLinkRouter()
        router.handle(.invite(senderID: "uid-maya"))
        #expect(router.pendingInviterID == "uid-maya")
        #expect(router.pendingFriendsTab)
        #expect(router.pendingStayEvent == false)
        #expect(router.pendingConversationUserID == nil)
    }

    /// The "don't clobber a deep link on sign-in" guard must cover both handler orders: an intent not yet acted on, and one that was.
    @Test func aPendingInviteIsVisibleBeforeItIsConsumed() {
        let router = DeepLinkRouter()
        #expect(router.hasPendingIntent == false)
        #expect(router.didRouteSinceSignIn == false)

        router.handle(.invite(senderID: "uid-maya"))
        #expect(router.hasPendingIntent)

        // What ContentView does when it acts on the intent.
        router.pendingFriendsTab = false
        router.didRouteSinceSignIn = true
        // The inviter is pending until FriendsPage resolves it, so the guard holds on either field alone.
        router.pendingInviterID = nil
        #expect(router.hasPendingIntent == false)
        #expect(router.didRouteSinceSignIn)
    }

    @Test func everyPendingIntentCountsTowardTheGuard() {
        let router = DeepLinkRouter()
        router.pendingStayEvent = true
        #expect(router.hasPendingIntent)
        router.pendingStayEvent = false

        router.pendingConversationUserID = "uid-shai"
        #expect(router.hasPendingIntent)
        router.pendingConversationUserID = nil

        router.pendingListingID = "listing-1"
        #expect(router.hasPendingIntent)
        router.pendingListingID = nil

        router.pendingInviterID = "uid-maya"
        #expect(router.hasPendingIntent)
    }

    @Test func vouchCopyPointsAtTheLinkWhenItNamesTheSender() {
        let message = InviteCopy.vouch(inviterName: "Maya", senderID: "uid-maya")
        #expect(message.hasPrefix("It's Maya. "))
        #expect(message.contains(InviteCopy.inviteURL(senderID: "uid-maya").absoluteString))
        #expect(message.contains("open my profile in the app"))
    }

    /// Without an ID there's no card to open, so the copy asks them to search and names who.
    @Test func vouchCopyFallsBackToSearchWithoutASender() {
        let message = InviteCopy.vouch(inviterName: "Maya")
        #expect(message.contains("search for Maya"))
        #expect(message.contains(InviteCopy.inviteURL().absoluteString))
        #expect(!message.contains("?from="))
    }

    @Test func tripAndHostInvitesCarryTheSenderToo() {
        let link = InviteCopy.inviteURL(senderID: "uid-maya").absoluteString
        let trip = InviteCopy.tripIntent(city: "Austin", inviterName: "Maya", senderID: "uid-maya")
        #expect(trip.contains("Austin"))
        #expect(trip.contains(link))

        let host = InviteCopy.askToHost(inviterName: "Maya", senderID: "uid-maya")
        #expect(host.contains(link))
    }

    /// Every invite surface sends a link a stranger's phone can actually open.
    /// A custom-scheme link in shared copy is the regression this catches.
    @Test func noSharedInviteCopyLeaksTheCustomScheme() {
        let messages = [
            InviteCopy.vouch(inviterName: "Maya", senderID: "uid-maya"),
            InviteCopy.vouch(inviterName: nil),
            InviteCopy.tripIntent(city: "Austin", inviterName: "Maya", senderID: "uid-maya"),
            InviteCopy.askToHost(inviterName: "Maya", senderID: "uid-maya")
        ]
        for message in messages {
            #expect(!message.contains("\(InviteCopy.customScheme)://"))
            #expect(message.contains("https://\(InviteCopy.webHost)"))
        }
    }
}

//
//  DeepLinkRouter.swift
//  freebnb
//

import Foundation
import Observation

@MainActor
@Observable
final class DeepLinkRouter {
    var pendingConversationUserID: String?

    /// A stay-event push the user tapped; ContentView switches to the Stays tab. Navigation-only, so acting on it directly is safe.
    var pendingStayEvent: Bool = false

    /// A saved listing opened from Spotlight; ContentView switches to Listings and pushes it if loaded. Navigation-only.
    var pendingListingID: String?

    /// Set when a child view (e.g. "Find Friends") wants the Friends tab; ContentView switches and resets it. Navigation-only.
    var pendingFriendsTab: Bool = false

    /// The sender of an opened invite link. ContentView switches to Friends and
    /// FriendsPage shows their card to add. Navigation-only: opening never creates an edge.
    var pendingInviterID: String?

    /// True while any intent above is waiting to be acted on.
    var hasPendingIntent: Bool {
        pendingConversationUserID != nil
            || pendingStayEvent
            || pendingFriendsTab
            || pendingListingID != nil
            || pendingInviterID != nil
    }

    /// Set by `ContentView` when it acts on an intent, cleared on sign-out. It covers
    /// a link followed while signed out: sign-in resets the tab to Listings and mustn't
    /// overwrite the requested destination, and checking this and `hasPendingIntent`
    /// gives the same outcome whichever runs first.
    var didRouteSinceSignIn = false

    /// What an incoming `freebnb://` URL asks for. Parsed apart from the app so routing is testable, and an unknown host is an explicit nil.
    enum Route: Equatable {
        case stays
        /// `senderID` is nil for a link naming nobody (an older invite, or shared before the profile loaded).
        case invite(senderID: String?)
    }

    /// Both invite shapes: the `https` Universal Link and the older `freebnb://` scheme, which the web page falls back to.
    static func route(for url: URL) -> Route? {
        switch url.scheme {
        case InviteCopy.customScheme:
            switch url.host {
            case "stays":
                return .stays
            case "invite":
                return .invite(senderID: inviter(in: url))
            default:
                return nil
            }
        case "https":
            // Only this host and path; a pasted string can reach here, so check rather than assume.
            guard url.host == InviteCopy.webHost,
                  normalizedPath(url) == InviteCopy.webPath
            else { return nil }
            return .invite(senderID: inviter(in: url))
        default:
            return nil
        }
    }

    /// Treats `/i/` and `/i` as the same path, since browsers and share sheets may add the slash.
    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// The sender named by the link, or nil; an empty `?from=` reads as absent so it still opens Friends.
    private static func inviter(in url: URL) -> String? {
        let senderID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == InviteCopy.inviterQueryItem }?
            .value
        return senderID?.isEmpty == false ? senderID : nil
    }

    /// Applies a parsed route. Every case only navigates and writes nothing, so acting on a tapped link needs no confirmation.
    func handle(_ route: Route) {
        switch route {
        case .stays:
            pendingStayEvent = true
        case .invite(let senderID):
            pendingInviterID = senderID
            pendingFriendsTab = true
        }
    }
}

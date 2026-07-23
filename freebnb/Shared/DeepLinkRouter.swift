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

    /// A stay-event push (new request / accepted / declined) the user tapped.
    /// Consumed by ContentView to switch to the Stays tab. Unlike an invite, this
    /// only navigates — it never mutates data — so acting on it directly is safe.
    var pendingStayEvent: Bool = false

    /// A saved listing the user opened from Spotlight search (feature 40).
    /// Consumed by ContentView, which switches to the Listings tab and pushes the
    /// listing if it's loaded. Navigation-only, so acting on it directly is safe.
    var pendingListingID: String?

    /// Set when a child view (e.g. the empty feed's "Find Friends" prompt) wants
    /// to send the user to the Friends tab. Consumed by ContentView, which
    /// switches tabs and resets this. Navigation-only, so acting on it directly
    /// is safe.
    var pendingFriendsTab: Bool = false

    /// The sender of an invite link the user just opened (`freebnb://invite?from=`).
    /// ContentView switches to Friends and FriendsPage shows that person's card,
    /// ready to add. Navigation-only, exactly like the fields above: opening an
    /// invite never creates an edge, so a forged link can do no more than show
    /// someone a name they could have searched for.
    var pendingInviterID: String?

    /// What an incoming `freebnb://` URL asks for. Parsed apart from the app so
    /// the routing can be tested without one, and so an unknown host is an
    /// explicit nil rather than a fallthrough that quietly does something.
    enum Route: Equatable {
        case stays
        /// `senderID` is nil for a link that names nobody: an older invite, or
        /// one shared before the sender's profile had loaded.
        case invite(senderID: String?)
    }

    static func route(for url: URL) -> Route? {
        guard url.scheme == "freebnb" else { return nil }
        switch url.host {
        case "stays":
            return .stays
        case "invite":
            let senderID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == InviteCopy.inviterQueryItem }?
                .value
            // Treat an empty value as absent, so `?from=` behaves like no query.
            return .invite(senderID: senderID?.isEmpty == false ? senderID : nil)
        default:
            return nil
        }
    }

    /// Applies a parsed route. Every case here only navigates; none of them
    /// writes anything, which is what makes acting on a link the user tapped
    /// safe without a confirmation.
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

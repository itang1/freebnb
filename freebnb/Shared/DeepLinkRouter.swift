//
//  DeepLinkRouter.swift
//  freebnb
//

import Foundation
import Observation

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

    /// An incoming `freebnb://invite` deep link awaiting the user's explicit
    /// confirmation. Set from the URL handler; consumed by ContentView once the
    /// user is signed in and the inviter has been validated. A deep link must
    /// never silently write a friend edge, so nothing acts on this directly.
    var pendingInvite: PendingInvite?
}

struct PendingInvite: Identifiable, Equatable {
    let inviterID: String

    /// The inviter's real display name, read from their profile. Always nil on
    /// an invite straight off a deep link, because the link is unsigned and so
    /// anything it claims about the inviter is attacker-controlled (S9). Only
    /// ContentView sets this, after fetching the profile behind `inviterID`.
    var inviterName: String?

    var id: String { inviterID }
}

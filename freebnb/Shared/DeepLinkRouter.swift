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
}

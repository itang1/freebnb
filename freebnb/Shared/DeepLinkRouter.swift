//
//  DeepLinkRouter.swift
//  freebnb
//

import Foundation
import Observation

@Observable
final class DeepLinkRouter {
    var pendingConversationUserID: String?

    /// An incoming `freebnb://invite` deep link awaiting the user's explicit
    /// confirmation. Set from the URL handler; consumed by ContentView once the
    /// user is signed in and the inviter has been validated. A deep link must
    /// never silently write a friend edge, so nothing acts on this directly.
    var pendingInvite: PendingInvite?
}

struct PendingInvite: Identifiable, Equatable {
    let inviterID: String
    var inviterName: String?
    var id: String { inviterID }
}

//
//  DeepLinkRouter.swift
//  freebnb
//

import Foundation

/// Routes deep links from push notification taps to in-app navigation.
/// Injected into the environment so ContentView can observe it and switch
/// tabs + open the relevant conversation.
@Observable
final class DeepLinkRouter {
    var pendingConversationUserID: String?
}

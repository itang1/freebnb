//
//  FeedSections.swift
//  freebnb
//
//  Why a listing is in your feed (feature 18), rendered as the explanatory chip
//  on each feed card. A pure derivation of (listing, viewer, friends), so it is
//  unit-tested directly rather than only observable by scrolling a signed-in
//  build.
//

import Foundation

/// The connection that put a listing in front of you, rendered as a chip on the
/// feed card so the graph is legible instead of implicit.
enum FeedReason: String, Equatable, Hashable, Sendable {
    case yourListing
    case friend

    var label: String {
        switch self {
        case .yourListing: return "Your listing"
        case .friend:      return "From a friend"
        }
    }

    var iconName: String {
        switch self {
        case .yourListing: return "house.fill"
        case .friend:      return "person.fill.checkmark"
        }
    }
}

enum FeedSections {
    /// Why `home` reached this viewer, or nil when the connection cannot be
    /// verified client-side.
    ///
    /// Every listing is friends-only, so in practice everything in the feed is
    /// yours or a friend's. The nil case covers a listing whose ACL still names
    /// the viewer after the friendship ended (the server rebuild is eventually
    /// consistent): under-claiming is the right failure here — a missing chip is
    /// a missed flourish, a wrong one is a false statement about who knows whom.
    ///
    /// An empty `myID` is a signed-out viewer, who has no network and therefore
    /// never earns a chip.
    static func reason(for home: Home, myID: String, friendIDs: Set<String>) -> FeedReason? {
        guard !myID.isEmpty else { return nil }
        if home.hostUserID == myID { return .yourListing }
        if friendIDs.contains(home.hostUserID) { return .friend }
        return nil
    }
}

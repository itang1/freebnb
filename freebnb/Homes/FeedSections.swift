//
//  FeedSections.swift
//  freebnb
//
//  Why a listing is in your feed, as the chip on each card. A pure derivation of (listing, viewer, friends), unit-tested directly.
//

import Foundation

/// The connection that put a listing in front of you, shown as a chip so the graph is legible.
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
    /// Why `home` reached this viewer, or nil when the connection can't be verified client-side. Everything in
    /// the feed is yours or a friend's; nil covers an ACL still naming a viewer after the friendship ended.
    /// Under-claiming is right: a missing chip is a missed flourish, a wrong one a false statement about who
    /// knows whom. An empty `myID` (signed out) has no network and never earns a chip.
    static func reason(for home: Home, myID: String, friendIDs: Set<String>) -> FeedReason? {
        guard !myID.isEmpty else { return nil }
        if home.hostUserID == myID { return .yourListing }
        if friendIDs.contains(home.hostUserID) { return .friend }
        return nil
    }
}

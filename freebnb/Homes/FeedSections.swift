//
//  FeedSections.swift
//  freebnb
//
//  Why a listing is in your feed (feature 18), and the rail of recent listings
//  from your network that leads it (feature 10). Both are pure derivations of
//  (listing, viewer, friends), so they are unit-tested directly rather than only
//  observable by scrolling a signed-in build.
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

    /// How recently a listing must have been created to lead the feed.
    static let newWindow: TimeInterval = 14 * 24 * 60 * 60

    /// The rail is a glance, not a second feed.
    static let railLimit = 10

    /// Listings someone in your network posted within `window`, newest first.
    ///
    /// Your own listings are excluded: the rail exists to show you where you could
    /// go, and you cannot visit yourself. A listing with no `createdAt` is also
    /// excluded rather than treated as ancient — "new" is a claim, and a document
    /// that cannot support it should not make it.
    ///
    /// These rows stay in the main feed below as well. The rail is a shortcut past
    /// the scroll, not a partition of it: lifting them out would make a friend's
    /// new listing vanish from where a returning user last saw it.
    ///
    /// The comparator falls through to the listing id so that rows sharing a
    /// timestamp have a total order, for the same reason `HomeStore.feed` does.
    static func newFromYourNetwork(
        _ homes: [Home],
        myID: String,
        friendIDs: Set<String>,
        now: Date = Date(),
        window: TimeInterval = newWindow,
        limit: Int = railLimit
    ) -> [Home] {
        let recent = homes.filter { home in
            guard let createdAt = home.createdAt,
                  now.timeIntervalSince(createdAt) <= window
            else { return false }
            switch reason(for: home, myID: myID, friendIDs: friendIDs) {
            case .friend:           return true
            case .yourListing, nil: return false
            }
        }
        let ordered = recent.sorted { a, b in
            let aDate = a.createdAt ?? .distantPast
            let bDate = b.createdAt ?? .distantPast
            if aDate != bDate { return aDate > bDate }
            return a.id < b.id
        }
        return Array(ordered.prefix(limit))
    }
}

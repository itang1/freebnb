//
//  NetworkReach.swift
//  freebnb
//
//  Makes the graph tangible (feature 34): "3 homes reachable through Priya". A
//  pure derivation of (visible listings, viewer, friends), like `FeedSections`,
//  so it is unit-tested directly rather than only seen by scrolling a signed-in
//  build. It reuses `FeedSections.reason`, so the one rule about who-knows-whom
//  lives in exactly one place.
//

import Foundation

struct NetworkReach: Equatable {
    /// One friend who hosts listings you can see, and how many.
    struct HostReach: Identifiable, Equatable {
        let friendID: String
        let displayName: String
        let homeCount: Int
        var id: String { friendID }
    }

    /// Friends who host at least one listing you can see, most homes first.
    let hosts: [HostReach]

    /// Listings that reached you only as a friend-of-a-friend. Counted but never
    /// attributed to a name: a user may read only their own friend edges, so which
    /// friend introduced them is unknowable client-side (the same limit
    /// `FeedSections.reason` works within). Guessing a name here would be a lie
    /// about the graph, which is exactly what this view exists to tell the truth
    /// about.
    let extendedCount: Int

    /// Every home the network puts within reach.
    var totalHomes: Int { hosts.reduce(0) { $0 + $1.homeCount } + extendedCount }

    var isEmpty: Bool { hosts.isEmpty && extendedCount == 0 }

    static let empty = NetworkReach(hosts: [], extendedCount: 0)

    /// Tallies `homes` by the connection that put each one in front of `myID`.
    ///
    /// `displayName` resolves a host UID to a name; a nil result falls back rather
    /// than dropping the friend, so a not-yet-loaded profile still contributes its
    /// homes to the count. An empty `myID` (signed-out or anonymous) has no network
    /// and reaches nothing.
    static func compute(
        homes: [Home],
        myID: String,
        friendIDs: Set<String>,
        displayName: (String) -> String?
    ) -> NetworkReach {
        guard !myID.isEmpty else { return .empty }

        var countsByHost: [String: Int] = [:]
        var extended = 0
        for home in homes {
            switch FeedSections.reason(for: home, myID: myID, friendIDs: friendIDs) {
            case .friend:
                countsByHost[home.hostUserID, default: 0] += 1
            case .friendOfFriend:
                extended += 1
            case .yourListing, .none:
                continue
            }
        }

        let hosts = countsByHost
            .map { hostID, count in
                HostReach(
                    friendID: hostID,
                    displayName: displayName(hostID) ?? "FreeBNB User",
                    homeCount: count
                )
            }
            // Most homes first; then by name and finally id so rows sharing a count
            // still have a stable total order, as `HomeStore.feed` does.
            .sorted { a, b in
                if a.homeCount != b.homeCount { return a.homeCount > b.homeCount }
                if a.displayName != b.displayName { return a.displayName < b.displayName }
                return a.friendID < b.friendID
            }

        return NetworkReach(hosts: hosts, extendedCount: extended)
    }
}

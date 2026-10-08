//
//  NetworkReach.swift
//  freebnb
//
//  Tallies how many listings each friend hosts, for the Friends list's "2 homes". Pure like `FeedSections`
//  (unit-tested directly) and reuses `FeedSections.reason`, so the who-knows-whom rule lives in one place.
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

    /// Every home the network puts within reach.
    var totalHomes: Int { hosts.reduce(0) { $0 + $1.homeCount } }

    var isEmpty: Bool { hosts.isEmpty }

    static let empty = NetworkReach(hosts: [])

    /// Tallies `homes` by the connection that put each in front of `myID`. `displayName` resolves a host UID;
    /// nil falls back rather than dropping the friend. An empty `myID` has no network and reaches nothing.
    static func compute(
        homes: [Home],
        myID: String,
        friendIDs: Set<String>,
        displayName: (String) -> String?
    ) -> NetworkReach {
        guard !myID.isEmpty else { return .empty }

        var countsByHost: [String: Int] = [:]
        for home in homes {
            switch FeedSections.reason(for: home, myID: myID, friendIDs: friendIDs) {
            case .friend:
                countsByHost[home.hostUserID, default: 0] += 1
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
            // Most homes first, then name, then id, giving a stable total order as `HomeStore.feed` does.
            .sorted { a, b in
                if a.homeCount != b.homeCount { return a.homeCount > b.homeCount }
                if a.displayName != b.displayName { return a.displayName < b.displayName }
                return a.friendID < b.friendID
            }

        return NetworkReach(hosts: hosts)
    }
}

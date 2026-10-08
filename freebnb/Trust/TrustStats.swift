//
//  TrustStats.swift
//  freebnb
//
//  The reputation numbers on a profile and every listing. They live on the world-readable
//  user document so cards render without a fetch per host, and only `recomputeTrustStats`
//  writes them (the rules pin the map against clients).
//

import Foundation

struct TrustStats: Codable, Hashable, Sendable {
    /// Stays this user hosted through to completion.
    var staysHosted: Int?
    /// Stays this user took as a guest, through to completion.
    var staysTaken: Int?
    /// Reviews written *about* this user, and their mean rating (1...5).
    var reviewCount: Int?
    var averageRating: Double?
    /// Set only by an out-of-band identity check (not yet wired); nil and false both render "not verified".
    var idVerified: Bool?

    var isVerified: Bool { idVerified == true }

    /// "4.8 ★ (12)", or nil when nobody has reviewed this user yet.
    var ratingText: String? {
        guard let averageRating, let reviewCount, reviewCount > 0 else { return nil }
        return String(format: "%.1f ★ (%d)", averageRating, reviewCount)
    }
}

extension TrustStats {
    /// Whole years since `createdAt`: "New here" / "1 year on FreeBNB" / "3 years on FreeBNB". Here so every trust number is phrased in one place.
    static func tenureText(joinedAt: Date?, now: Date = Date()) -> String? {
        guard let joinedAt else { return nil }
        let years = Calendar.current.dateComponents([.year], from: joinedAt, to: now).year ?? 0
        if years < 1 { return "New here" }
        return "\(years) year\(years == 1 ? "" : "s") on FreeBNB"
    }
}

/// How many friends we have in common with one other user, from the `mutualFriends` callable (`friendEdges` is readable only by the two people).
struct MutualFriends: Codable, Hashable, Sendable {
    var count: Int
    /// A few names to make the number concrete ("Priya, Sam and 3 others").
    var names: [String]

    static let empty = MutualFriends(count: 0, names: [])

    /// A name-free count for the profile pill: "1 mutual friend",
    /// "3 mutual friends", or nil when there are none.
    var countSummary: String? {
        // swiftlint:disable:next empty_count
        guard count > 0 else { return nil }
        return "\(count) mutual friend\(count == 1 ? "" : "s")"
    }

    /// "Priya and Sam", "Priya, Sam and 3 others", or nil when there are none.
    var summary: String? {
        // `count` is the callable's total and can exceed `names.count`, so `names.isEmpty` isn't equivalent.
        // swiftlint:disable:next empty_count
        guard count > 0 else { return nil }
        let shown = names.prefix(2)
        let remainder = count - shown.count
        switch (shown.count, remainder) {
        case (0, _):  return "\(count) mutual friend\(count == 1 ? "" : "s")"
        case (_, 0):  return shown.joined(separator: " and ")
        default:      return "\(shown.joined(separator: ", ")) and \(remainder) other\(remainder == 1 ? "" : "s")"
        }
    }
}

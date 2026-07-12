//
//  TrustStats.swift
//  freebnb
//
//  The reputation numbers shown on a profile and on every listing (feature 2).
//  They live on the world-readable `users/{uid}` document because a listing card
//  must render them without a second fetch per host, and they are written only
//  by the `recomputeTrustStats` Cloud Function — `firestore.rules` pins the map
//  against client writes, so a host cannot inflate their own numbers.
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
    /// Share of received stay requests this user answered rather than left
    /// hanging: `respondedCount / receivedCount`. Nil until they've received
    /// enough requests for the number to mean anything (see `minimumResponses`).
    var responseRate: Double?
    var respondedCount: Int?
    var receivedCount: Int?
    /// Set only by an out-of-band identity check (feature 3, not yet wired to a
    /// provider). Nil and false both render as "not verified".
    var idVerified: Bool?

    /// Below this many received requests a response rate is noise, not a signal,
    /// so the server leaves `responseRate` nil and the UI shows no chip.
    static let minimumResponses = 3

    var isVerified: Bool { idVerified == true }

    /// "92% response rate", or nil when there isn't enough data to say.
    var responseRateText: String? {
        guard let responseRate else { return nil }
        return "\(Int((responseRate * 100).rounded()))% response rate"
    }

    /// "4.8 ★ (12)", or nil when nobody has reviewed this user yet.
    var ratingText: String? {
        guard let averageRating, let reviewCount, reviewCount > 0 else { return nil }
        return String(format: "%.1f ★ (%d)", averageRating, reviewCount)
    }
}

extension TrustStats {
    /// Whole years since `createdAt`, as "New here" / "1 year on FreeBNB" / "3
    /// years on FreeBNB". Lives here rather than on `UserProfile` so every trust
    /// number is phrased in one place.
    static func tenureText(joinedAt: Date?, now: Date = Date()) -> String? {
        guard let joinedAt else { return nil }
        let years = Calendar.current.dateComponents([.year], from: joinedAt, to: now).year ?? 0
        if years < 1 { return "New here" }
        return "\(years) year\(years == 1 ? "" : "s") on FreeBNB"
    }
}

/// The answer to "how many friends do we have in common" for one other user,
/// computed by the `mutualFriends` callable because `friendEdges` is readable
/// only by the two people it connects.
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
        // `count` is the callable's total, not a collection length: it can
        // exceed `names.count`, so `names.isEmpty` is not an equivalent check.
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

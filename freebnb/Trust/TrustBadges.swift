//
//  TrustBadges.swift
//  freebnb
//
//  The reputation chips shown on a listing and on a profile (feature 2). One
//  view so the two surfaces cannot drift apart and start phrasing the same
//  number differently.
//

import SwiftUI

/// A single capsule chip. Neutral by default; `tint` marks the earned ones.
struct TrustChip: View {
    let text: String
    let systemImage: String
    var tint: Color?

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundColor(tint ?? .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((tint ?? .secondary).opacity(tint == nil ? 0.08 : 0.12))
            .clipShape(Capsule())
            .accessibilityLabel(text)
    }
}

/// Every trust signal we have for one user, in a wrapping row.
///
/// Chips are omitted rather than zeroed: "0 stays hosted" reads as a warning
/// about a new host, when it only means the platform has nothing to say yet.
/// A number that isn't there is honest; a zero is an accusation.
struct TrustBadgeRow: View {
    let profile: UserProfile?
    /// Mutual friends between the viewer and this user, when known. Omitted on
    /// your own profile, where the question is meaningless.
    var mutualFriends: MutualFriends?
    /// Set on the host's own listing to leave out the social chips.
    var isSelf: Bool = false

    private var stats: TrustStats { profile?.effectiveTrustStats ?? TrustStats() }

    var body: some View {
        FlowRow(spacing: 6) {
            if stats.isVerified {
                TrustChip(text: "ID verified", systemImage: "checkmark.seal.fill", tint: Color.accent)
            }

            if let rating = stats.ratingText {
                TrustChip(text: rating, systemImage: "star.fill", tint: .orange)
            }

            if let hosted = stats.staysHosted, hosted > 0 {
                TrustChip(text: "\(hosted) stay\(hosted == 1 ? "" : "s") hosted", systemImage: "house")
            }

            if let taken = stats.staysTaken, taken > 0 {
                TrustChip(text: "\(taken) stay\(taken == 1 ? "" : "s") taken", systemImage: "suitcase")
            }

            if let rate = stats.responseRateText {
                TrustChip(text: rate, systemImage: "clock.arrow.circlepath")
            }

            if let tenure = profile?.tenureText {
                TrustChip(text: tenure, systemImage: "calendar")
            }

            if !isSelf, let summary = mutualFriends?.countSummary {
                TrustChip(text: summary, systemImage: "person.2.fill", tint: Color.accent)
            }
        }
    }
}

/// A minimal wrapping HStack. SwiftUI has no built-in flow layout, and chips
/// that clip off the trailing edge silently hide the very signals the row exists
/// to show.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = layout(subviews: subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, in: bounds.width) {
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                proposal: ProposedViewSize(width: row.width, height: row.height)
            )
        }
    }

    private struct Placement {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private func layout(subviews: Subviews, in maxWidth: CGFloat) -> [Placement] {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // Wrap before placing, unless this is the first chip on the row —
            // a single chip wider than the container still has to go somewhere.
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(Placement(index: index, x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return placements
    }
}

#Preview {
    TrustBadgeRow(
        profile: UserProfile(
            id: "u1",
            displayName: "Priya",
            trustStats: TrustStats(
                staysHosted: 12,
                staysTaken: 3,
                reviewCount: 9,
                averageRating: 4.8,
                responseRate: 0.92,
                respondedCount: 12,
                receivedCount: 13,
                idVerified: true
            ),
            createdAt: Calendar.current.date(byAdding: .year, value: -3, to: Date())
        ),
        mutualFriends: MutualFriends(count: 4, names: ["Sam", "Alex"])
    )
    .padding()
}

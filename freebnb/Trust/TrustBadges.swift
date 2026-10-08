//
//  TrustBadges.swift
//  freebnb
//
//  The reputation chips on a listing and a profile, one view so the two never phrase a number differently.
//

import SwiftUI

/// A single capsule chip. Neutral by default; `tint` marks earned ones. Color carries
/// meaning, so it's spent sparingly: green for platform assurance, teal for your
/// network, amber for guest ratings.
struct TrustChip: View {
    let text: String
    let systemImage: String
    var tint: Color?

    private var isEarned: Bool { tint != nil }
    private var color: Color { tint ?? .secondary }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(isEarned ? .semibold : .medium))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(isEarned ? 0.15 : 0.09), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// Every trust signal for one user, in two tiers: earned signals keep their chips
/// and colour, and plain counts drop to one quiet line of text. Signals are omitted
/// rather than zeroed, since "0 stays hosted" reads as a warning about a new host.
struct TrustBadgeRow: View {
    let profile: UserProfile?
    /// Mutual friends between the viewer and this user, when known; omitted on your own profile.
    var mutualFriends: MutualFriends?
    /// Set on the host's own listing to leave out the social chips.
    var isSelf: Bool = false

    private var stats: TrustStats { profile?.effectiveTrustStats ?? TrustStats() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasEarnedChips {
                FlowRow(spacing: 6) {
                    if stats.isVerified {
                        // Green, not brand teal, so identity assurance stays distinct from the teal "mutual
                        // friends" chip.
                        TrustChip(text: "ID verified", systemImage: "checkmark.seal.fill", tint: .success)
                    }
                    if let rating = stats.ratingText {
                        TrustChip(text: rating, systemImage: "star.fill", tint: .orange)
                    }
                    if !isSelf, let summary = mutualFriends?.countSummary {
                        TrustChip(text: summary, systemImage: "person.2.fill", tint: Color.accent)
                    }
                }
            }

            if let strip = statsStrip {
                Text(strip)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .accessibilityLabel(statsAccessibilityLabel)
            }
        }
    }

    private var hasEarnedChips: Bool {
        stats.isVerified
            || stats.ratingText != nil
            || (!isSelf && mutualFriends?.countSummary != nil)
    }

    /// The plain counts, middot-separated ("12 hosted · 3 taken · 3 years on FreeBNB"); nil when none are known.
    private var statsStrip: String? {
        var parts: [String] = []
        if let hosted = stats.staysHosted, hosted > 0 { parts.append("\(hosted) hosted") }
        if let taken = stats.staysTaken, taken > 0 { parts.append("\(taken) taken") }
        if let tenure = profile?.tenureText { parts.append(tenure) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The strip read aloud: the compact form announces as fragments, so VoiceOver gets the full phrasing.
    private var statsAccessibilityLabel: String {
        var parts: [String] = []
        if let hosted = stats.staysHosted, hosted > 0 {
            parts.append("\(hosted) stay\(hosted == 1 ? "" : "s") hosted")
        }
        if let taken = stats.staysTaken, taken > 0 {
            parts.append("\(taken) stay\(taken == 1 ? "" : "s") taken")
        }
        if let tenure = profile?.tenureText { parts.append(tenure) }
        return parts.joined(separator: ", ")
    }
}

/// A minimal wrapping HStack; SwiftUI has no built-in flow layout, and clipped chips would hide signals.
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
            // Wrap before placing unless first on the row; an over-wide chip still has to go somewhere.
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
                idVerified: true
            ),
            createdAt: Calendar.current.date(byAdding: .year, value: -3, to: Date())
        ),
        mutualFriends: MutualFriends(count: 4, names: ["Sam", "Alex"])
    )
    .padding()
}

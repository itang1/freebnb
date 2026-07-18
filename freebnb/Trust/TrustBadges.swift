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
///
/// Color carries meaning here, so it is spent sparingly: a factual stat stays
/// grey and quiet, while an *earned* signal takes a semantic tint and a heavier
/// weight so the eye lands on it first. The three tints each mean one thing —
/// green for platform assurance, teal for your network, amber for guest ratings —
/// so no two earned chips ever read as the same kind of signal.
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

/// Every trust signal we have for one user.
///
/// Two tiers, because the old single row of seven chips ate most of a phone's
/// first screen before the profile said anything. The *earned* signals — the
/// ones a person had to do something to get — keep their chips and their colour.
/// The plain counts drop to one quiet line of text underneath: still every
/// number, still exact, just no longer seven capsules competing with each other.
/// Nothing is hidden or collapsed behind a tap.
///
/// Signals are omitted rather than zeroed: "0 stays hosted" reads as a warning
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
        VStack(alignment: .leading, spacing: 8) {
            if hasEarnedChips {
                FlowRow(spacing: 6) {
                    if stats.isVerified {
                        // Green, not brand teal: identity assurance is a safety
                        // signal, and keeping it distinct from the teal "mutual
                        // friends" chip means the two never blur into one
                        // "trusted" colour.
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
                    .foregroundColor(.secondary)
                    .accessibilityLabel(statsAccessibilityLabel)
            }
        }
    }

    private var hasEarnedChips: Bool {
        stats.isVerified
            || stats.ratingText != nil
            || (!isSelf && mutualFriends?.countSummary != nil)
    }

    /// The plain counts, middot-separated: "12 hosted · 3 taken · 92% response ·
    /// 3 years on FreeBNB". Nil when we know none of them, so a brand-new profile
    /// renders no empty line.
    private var statsStrip: String? {
        var parts: [String] = []
        if let hosted = stats.staysHosted, hosted > 0 { parts.append("\(hosted) hosted") }
        if let taken = stats.staysTaken, taken > 0 { parts.append("\(taken) taken") }
        if let rate = stats.responseRate { parts.append("\(Int((rate * 100).rounded()))% response") }
        if let tenure = profile?.tenureText { parts.append(tenure) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The strip read aloud as words. "12 hosted · 3 taken" is compact enough to
    /// scan but announces as run-together fragments, so VoiceOver gets the
    /// unabbreviated phrasing the chips used to carry.
    private var statsAccessibilityLabel: String {
        var parts: [String] = []
        if let hosted = stats.staysHosted, hosted > 0 {
            parts.append("\(hosted) stay\(hosted == 1 ? "" : "s") hosted")
        }
        if let taken = stats.staysTaken, taken > 0 {
            parts.append("\(taken) stay\(taken == 1 ? "" : "s") taken")
        }
        if let rate = stats.responseRateText { parts.append(rate) }
        if let tenure = profile?.tenureText { parts.append(tenure) }
        return parts.joined(separator: ", ")
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

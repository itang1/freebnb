//
//  SkeletonView.swift
//  freebnb
//

import SwiftUI

private struct SkeletonModifier: ViewModifier {
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // A repeatForever pulse is exactly the kind of looping animation
            // Reduce Motion exists to stop; hold a steady mid opacity instead.
            .opacity(reduceMotion ? 0.6 : (animating ? 0.4 : 0.9))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.appTeal.opacity(0.25))
            .frame(width: width, height: height)
            .modifier(SkeletonModifier())
    }
}

struct SkeletonHomeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photo placeholder
            Color.appTeal.opacity(0.18)
                .frame(height: 190)
                .modifier(SkeletonModifier())
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 20
                ))

            VStack(alignment: .leading, spacing: 10) {
                // Summary pills
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock(width: 70, height: 26, cornerRadius: 13)
                    }
                }

                // Amenity row
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonBlock(width: 32, height: 32, cornerRadius: 8)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.skyBlue.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.appTeal.opacity(0.10), radius: 8, x: 0, y: 5)
    }
}

struct SkeletonConversationRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 44, height: 44, cornerRadius: 22)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 120, height: 14)
                SkeletonBlock(width: 200, height: 12, cornerRadius: 5)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// A single placeholder chat bubble. `isMine` mirrors the real thread's
/// leading/trailing alignment so the skeleton settles into the loaded layout
/// without the rows jumping sides.
struct SkeletonMessageBubble: View {
    var isMine: Bool
    var width: CGFloat

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            SkeletonBlock(width: width, height: 34, cornerRadius: 18)
            if !isMine { Spacer(minLength: 40) }
        }
    }
}

/// Alternating placeholder bubbles for a thread whose first snapshot is still
/// in flight. Widths are fixed rather than random so the shape is stable across
/// the re-renders SwiftUI performs while the view is on screen.
struct SkeletonMessageThread: View {
    private static let bubbles: [(isMine: Bool, width: CGFloat)] = [
        (false, 180), (true, 140), (false, 220), (true, 96), (false, 160)
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(Self.bubbles.enumerated()), id: \.offset) { _, bubble in
                SkeletonMessageBubble(isMine: bubble.isMine, width: bubble.width)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

/// Placeholder for the listing detail map while the address is geocoded.
/// Matches the loaded map's 250pt height and corner radius so the swap is
/// a crossfade rather than a reflow.
struct SkeletonMapBlock: View {
    var body: some View {
        SkeletonBlock(height: 250, cornerRadius: 12)
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Loading map")
    }
}

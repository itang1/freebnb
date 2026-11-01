//
//  EmptyStateView.swift
//  freebnb
//
//  The app's empty states as little tide pools: stock ContentUnavailableView's grey glyph reads as a dead
//  end, while these are invitations. One view keeps every quiet screen consistent.
//

import SwiftUI

/// The illustration alone: an SF Symbol floating in a round tide pool, a sky flower blooming behind it
/// and bubbles rising, for screens with their own text layout. The symbol bobs and the bubbles drift
/// unless Reduce Motion is on.
struct EmptyStateMedallion: View {
    let systemImage: String

    var body: some View {
        ZStack {
            // A big conch-pink sky flower peeking out from behind the pool, top right.
            SkyFlowerMark(petalColor: .tertiaryBackground, heartColor: .sunshine)
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(18))
                .offset(x: 44, y: -34)

            // The pool: seafoam water with a wave rolling across its lower half, rimmed in sand.
            Circle()
                .fill(Color.secondaryAccent)
                .overlay(alignment: .bottom) {
                    WaveShape(amplitude: 4, wavelength: 44, phase: 0.2)
                        .fill(Color.accent.opacity(0.18))
                        .frame(height: 46)
                }
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.sunshine.opacity(0.9), lineWidth: 5))
                .frame(width: 112, height: 112)

            BubbleField(count: 5)
                .frame(width: 96, height: 120)
                .offset(x: -6, y: -18)

            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accent)
                .bobbing(amplitude: 3, period: 3.6, tilt: 3)
        }
        // A fixed frame around the pool, so the flower and bubbles never shift the layout around them.
        .frame(width: 150, height: 150)
        .accessibilityHidden(true)
    }
}

/// Title, tide-pool medallion, message and optional actions row; sizing and background stay with the call site.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: Actions

    init(
        title: String,
        systemImage: String,
        message: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            EmptyStateMedallion(systemImage: systemImage)
                .padding(.bottom, 8)
            Text(title)
                .font(.display(.title3))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            actions
                .padding(.top, 8)
        }
    }
}

#Preview("Full screen") {
    EmptyStateView(
        title: ThemeCopy.Empty.tripsTitle,
        systemImage: ThemeCopy.Tab.tripsIcon,
        message: ThemeCopy.Empty.tripsMessage
    ) {
        Button("Browse Listings") {}
            .buttonStyle(.lagoon)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .lagoonBackground()
}

#Preview("Medallion only") {
    EmptyStateMedallion(systemImage: "message")
        .padding()
        .background(Color.primaryBackground)
}

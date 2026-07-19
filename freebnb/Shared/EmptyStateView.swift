//
//  EmptyStateView.swift
//  freebnb
//
//  The app's empty states, drawn in seafoam. Stock ContentUnavailableView
//  renders a grey glyph on the cream background, which reads as a dead end;
//  these screens are invitations ("message a host", "add a friend"), so they
//  get the palette's water tone instead. One view so every quiet screen sits
//  on the same treatment, and the seafoam role stays reserved for atmosphere
//  rather than leaking into controls.
//

import SwiftUI

/// The illustration part alone: an SF Symbol in brand teal on overlapping
/// seafoam pools. Split out for screens that keep their own text layout (the
/// feed's empty state, the message thread's placeholder) but should still
/// match the rest of the app's quiet moments.
struct EmptyStateMedallion: View {
    let systemImage: String

    var body: some View {
        ZStack {
            // Offset behind the main pool like light on water; opacity rather
            // than a second color so dark mode's seafoam variant carries both.
            Circle()
                .fill(Color.secondaryAccent.opacity(0.4))
                .frame(width: 130, height: 130)
                .offset(x: 20, y: 12)
            Circle()
                .fill(Color.secondaryAccent)
                .frame(width: 104, height: 104)
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.accent)
        }
        // Padding absorbs the offset pool so the medallion centers on the
        // *main* circle instead of the ZStack's lopsided bounds.
        .padding(.trailing, 20)
        .padding(.bottom, 12)
        .accessibilityHidden(true)
    }
}

/// Title, seafoam medallion, message, and an optional actions row. Sizing and
/// background stay with the call site: full-screen voids want
/// `.frame(maxWidth:.infinity, maxHeight:.infinity)`, a List row doesn't.
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
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            actions
                .padding(.top, 8)
        }
    }
}

#Preview("Full screen") {
    EmptyStateView(
        title: "No trips yet",
        systemImage: "suitcase",
        message: "Open a listing, message the host, and request to stay. Your trips appear here."
    ) {
        Button("Browse Listings") {}
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.primaryBackground.ignoresSafeArea())
}

#Preview("Medallion only") {
    EmptyStateMedallion(systemImage: "message")
        .padding()
        .background(Color.primaryBackground)
}

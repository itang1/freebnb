//
//  WhatsNewPage.swift
//  freebnb
//
//  Renders the `WhatsNew` changelog (feature 43). Doubles as a navigable Info page
//  and, when handed an `onDismiss`, as the auto-presented "what's new" sheet. A
//  highlight with a `longRead` pushes `HighlightReaderPage`; this is also where the
//  old "Feature Spotlight" reader page moved to.
//

import SwiftUI

struct WhatsNewPage: View {
    /// When non-nil, a "Done" button is shown and this is called on tap, so the
    /// same view serves both the pushed Info page and the presented sheet.
    var onDismiss: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(WhatsNew.releases) { release in
                    releaseSection(release)
                }
            }
            .frame(maxWidth: 600)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("What's New")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func releaseSection(_ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(release.version)")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text(release.date)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            if let intro = release.intro {
                Text(intro)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(release.highlights) { highlight in
                if let longRead = highlight.longRead {
                    NavigationLink(
                        destination: HighlightReaderPage(highlight: highlight, longRead: longRead, date: release.date)
                    ) {
                        highlightRow(highlight, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    highlightRow(highlight, showsChevron: false)
                }
            }
        }
        .padding(16)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func highlightRow(_ highlight: ReleaseHighlight, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: highlight.icon)
                .font(.title3)
                .foregroundColor(.onAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accent.opacity(0.85)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(highlight.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsChevron {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Color.accent.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps `WhatsNewPage` in its own `NavigationStack` for sheet presentation.
struct WhatsNewSheet: View {
    let onDismiss: () -> Void
    var body: some View {
        NavigationStack {
            WhatsNewPage(onDismiss: onDismiss)
        }
    }
}

/// The full read behind a highlight's `longRead`, formerly the "Feature Spotlight"
/// article page.
struct HighlightReaderPage: View {
    let highlight: ReleaseHighlight
    let longRead: String
    let date: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: highlight.icon)
                    .font(.title)
                    .foregroundColor(.onAccent)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accent.opacity(0.85)))
                    .accessibilityHidden(true)

                Text(date)
                    .font(.caption)
                    .foregroundColor(.secondaryText)

                Text(highlight.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(longRead)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("What's New")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack { WhatsNewPage() }
}

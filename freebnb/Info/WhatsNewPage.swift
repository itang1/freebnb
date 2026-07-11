//
//  WhatsNewPage.swift
//  freebnb
//
//  Renders the `WhatsNew` changelog (feature 43). Doubles as a navigable Info page
//  and, when handed an `onDismiss`, as the auto-presented "what's new" sheet.
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
                    .foregroundColor(.secondary)
            }

            ForEach(release.highlights) { highlight in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: highlight.icon)
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.accent.opacity(0.85)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlight.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(highlight.detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(Color.secondaryBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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

#Preview {
    NavigationStack { WhatsNewPage() }
}

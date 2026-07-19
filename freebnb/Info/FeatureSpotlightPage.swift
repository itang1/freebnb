//
//  FeatureSpotlightPage.swift
//  freebnb
//
//  Renders the `FeatureSpotlight` column: a list of short pieces, each opening on
//  its own reader page. Reached from `InfoPage`. Static, hand-curated content, so
//  it needs no network and ships with the build.
//

import SwiftUI

struct FeatureSpotlightPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Short reads on getting the most out of FreeBNB. A new one lands from time to time.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                ForEach(FeatureSpotlight.articles) { article in
                    NavigationLink(destination: SpotlightArticlePage(article: article)) {
                        articleCard(article)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 600)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Feature Spotlight")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func articleCard(_ article: SpotlightArticle) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: article.icon)
                .font(.title3)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accent.opacity(0.85)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(article.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(article.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color.accent.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// The full read for one spotlight piece.
struct SpotlightArticlePage: View {
    let article: SpotlightArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: article.icon)
                    .font(.title)
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accent.opacity(0.85)))
                    .accessibilityHidden(true)

                Text(article.date)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(article.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(article.body)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Feature Spotlight")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack { FeatureSpotlightPage() }
}

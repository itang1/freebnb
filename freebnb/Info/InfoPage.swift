//
//  InfoPage.swift
//  freebnb
//

import SwiftUI

struct InfoPage: View {
    @Environment(\.openURL) private var openURL
    @State private var showFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Learn about what FreeBNB offers and how to make the most of your stays.")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 4)

                NavigationLink(destination: WhatsNewPage()) {
                    InfoCard(
                        icon: "sparkles",
                        title: "What's New",
                        subtitle: "The latest features, and how they work"
                    )
                }

                NavigationLink(destination: AboutPage()) {
                    InfoCard(
                        icon: "heart.fill",
                        title: "About FreeBNB",
                        subtitle: "Our mission and story"
                    )
                }

                NavigationLink(destination: HowItWorksPage()) {
                    InfoCard(
                        icon: "arrow.right.circle.fill",
                        title: "How It Works",
                        subtitle: "Step-by-step for guests and hosts"
                    )
                }

                NavigationLink(destination: FeaturesPage()) {
                    InfoCard(
                        icon: "star.fill",
                        title: "Overview",
                        subtitle: "What FreeBNB offers"
                    )
                }

                NavigationLink(destination: FAQPage()) {
                    InfoCard(
                        icon: "questionmark.circle.fill",
                        title: "FAQ",
                        subtitle: "Common questions answered"
                    )
                }

                NavigationLink(destination: GuestTipsPage()) {
                    InfoCard(
                        icon: "lightbulb.fill",
                        title: "Guest Tips",
                        subtitle: "Be a great house guest"
                    )
                }

                NavigationLink(destination: SafetyGuidelinesPage()) {
                    InfoCard(
                        icon: "shield.checkered",
                        title: "Safety Guidelines",
                        subtitle: "Stay safe and set boundaries"
                    )
                }

                Button {
                    openURL(LegalLinks.privacyPolicy)
                } label: {
                    InfoCard(
                        icon: "hand.raised",
                        title: "Privacy Policy",
                        subtitle: "What we collect and how it's used"
                    )
                }

                Button {
                    openURL(LegalLinks.termsOfService)
                } label: {
                    InfoCard(
                        icon: "doc.text",
                        title: "Terms of Service",
                        subtitle: "The rules for using FreeBNB"
                    )
                }

                Button {
                    showFeedback = true
                } label: {
                    InfoCard(
                        icon: "bubble.left.and.text.bubble.right.fill",
                        title: "Send Feedback",
                        subtitle: "Ideas, problems, or praise"
                    )
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primaryBackground)
        .navigationTitle("FreeBNB Information")
        .sheet(isPresented: $showFeedback) {
            FeedbackComposerView()
        }
    }
}

private struct InfoCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            // Icon in a soft teal bubble
            Image(systemName: icon)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.onAccent)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(Color.accent.opacity(0.85))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(Color.accent.opacity(0.6))
        }
        .padding(14)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.accent.opacity(0.25), radius: 10, x: 0, y: 5)
    }
}

#Preview {
    NavigationStack {
        InfoPage()
    }
    .previewEnvironment()
}

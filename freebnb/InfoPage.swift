//
//  InfoPage.swift
//  freebnb
//
//  Created by Irene Tang on 4/3/26.
//

import SwiftUI

struct InfoPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Learn about what FreeBNB offers and how to make the most of your stays.")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 4)

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
                        title: "Features",
                        subtitle: "What FreeBNB offers"
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

                NavigationLink(destination: FAQPage()) {
                    InfoCard(
                        icon: "questionmark.circle.fill",
                        title: "FAQ",
                        subtitle: "Common questions answered"
                    )
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.creamWhite)
        .navigationTitle("FreeBNB Information")
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.mintGreen)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.primary)
        }
        .padding()
        .background(Color.seafoamBlue.opacity(0.5))
        .cornerRadius(12)
    }
}

#Preview {
    NavigationStack {
        InfoPage()
    }
}

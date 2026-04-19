//
//  FeaturesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/24/25.
//

import SwiftUI

struct FeatureCard: View {
    let iconName: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 35) {
            Image(systemName: iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundColor(Color("AppTeal"))
                .frame(width: 60, height: 60)

            Text(description)
                .multilineTextAlignment(.leading)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cornerRadius(12)
    }
}

struct FeaturesPage: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 35) {
                FeatureCard(
                    iconName: "figure.ice.skating",
                    description: "Hosts can mark when their guest room is available. Set limits for stay length, number of guests, etc."
                )
                FeatureCard(
                    iconName: "figure.outdoor.rowing",
                    description: "Guests can browse available stays. Request one in just a few taps."
                )
                FeatureCard(
                    iconName: "ruler",
                    description: "View photos, room descriptions, amenities, and house rules."
                )
                FeatureCard(
                    iconName: "person.badge.shield.checkmark",
                    description: "Your listing is only visible to people you've approved."
                )
                FeatureCard(
                    iconName: "bell.fill",
                    description: "Set simple reminders to visit friends or reconnect with people you haven't seen in a while."
                )
                FeatureCard(
                    iconName: "gift.fill",
                    description: "No fees, middlemen, or hidden costs. Just free."
                )
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.creamWhite)
        .navigationTitle("Features")
    }
}

#Preview {
    NavigationStack {
        FeaturesPage()
    }
}

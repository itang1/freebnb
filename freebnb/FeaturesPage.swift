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
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 60, height: 60)

                Image(systemName: iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.accentColor)
            }
            .frame(width: 60, height: 60)

            Text(description)
                .multilineTextAlignment(.leading)
                .font(.body)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cornerRadius(12)
    }
}

struct FeaturesPage: View {
    var onViewListings: () -> Void

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 30) {
                    FeatureCard(
                        iconName: "figure.ice.skating",
                        description: "Hosts can mark when their guest room is available. Set limits for stay length, number of guests, etc."
                    )
                    FeatureCard(
                        iconName: "figure.outdoor.rowing",
                        description: "Guests can see where their loved ones are. Browse available stays from people you know, and request one in just a few taps."
                    )
                    FeatureCard(
                        iconName: "ruler",
                        description: "View photos, room descriptions, amenities, and house rules before you stay."
                    )
                    FeatureCard(
                        iconName: "person.badge.shield.checkmark",
                        description: "Your listing is only visible to people you've approved."
                    )
                    FeatureCard(
                        iconName: "heart.slash.circle",
                        description: "No landlords. No price gouging. No platform fees. Just free."
                    )
                }
                .frame(maxWidth: 600)
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Button(action: {
                print("View Listings tapped!")
                onViewListings()
            }) {
                Text("View Listings")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }

            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Features")
    }
}

#Preview {
    FeaturesPage(onViewListings: {
        print("Preview: onViewListings triggered")
    })
}

//
//  AboutPage.swift
//  freebnb
//
//  Created by Irene Tang on 4/3/26.
//

import SwiftUI

struct AboutPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // App icon / hero
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "house.lodge.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .foregroundColor(Color("AppTeal"))

                        Text("FreeBNB")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("The guest rooms of people you know")
                            .font(.subheadline)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                // Mission
                SectionBlock(
                    title: "Our Mission",
                    text: "Freebnb helps people stay connected across cities, time, and life changes. Completely free. No fees. No transactions. No pressure. Just people opening their doors to those they care about."
                )

                // What makes us different
                SectionBlock(
                    title: "A Different Kind of Platform",
                    text: "Most platforms take. Freebnb gives. No fees. No commissions. No incentives to turn homes into businesses. Just a simple idea: if you have space, and someone you trust needs it, then you can help."
                )

                // How it started
                SectionBlock(
                    title: "How It Started",
                    text: "We kept running into the same problem: some want to travel and others want to be visited, but trips never got off the ground. High lodging costs, the fear of being a burden, the awkwardness of asking, not knowing who's actually open to connecting—all of that is discouraging. FreeBNB fixes that by showing you exactly who in your circle is ready to host or travel, so \"we should hang out sometime\" finally becomes \"go book your flight.\""
                )

                // Why free
                SectionBlock(
                    title: "Why Free?",
                    text: "With hotels being expensive and short-term rental platforms requiring excessive fees, cost often prohibits us from visiting the people we love. Freebnb chips away at that barrier. Hosts share their space because they want to see you too, not because they want to profit."
                )

                // Values
                SectionBlock(
                    title: "What We Believe",
                    text: "Generosity is contagious. A good guest becomes a great host. Community is built one spare room at a time. Business should bring people closer, not extract profit from them."
                )
                
                // Big Picture
                SectionBlock(
                    title: "The Bigger Idea",
                    text: "We live in a world where people move constantly to new cities, new jobs, new chapters, new circles. Slowly, without realizing it, we lose touch. Freebnb is a way to reconnect and make the distance feel smaller. Turn scattered friendships back into real, living relationships."
                )
                
                // Future Work
                SectionBlock(
                    title: "Beyond Friends and Family (Coming Soon)",
                    text: "Freebnb isn't just about personal networks. Soon, hosts will be able to offer their spaces to nonprofits, traveling volunteers, community groups, and people in need of temporary housing. Unused space can do real good, and we want to unlock that potential. We're actively exploring how to make that happen while staying true to our mission and values."
                )
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.creamWhite)
        .navigationTitle("About FreeBNB")
    }
}

struct SectionBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    NavigationStack {
        AboutPage()
    }
}

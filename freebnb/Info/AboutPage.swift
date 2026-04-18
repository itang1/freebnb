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
                    text: "Freebnb helps people stay connected across cities, time, and life changes. We support people opening their doors to those they care about, with no fees and no pressure."
                )

                // Why free
                SectionBlock(
                    title: "Why Free?",
                    text: "Some people want to travel, and others want to be visited. But with high lodging costs, the fear of being a burden, and the awkwardness of asking without knowing who's actually open to connecting, so many trips often don't happen.\n\nFreeBNB tears down this barrier by showing you exactly who in your circle is ready to host or travel, so that connections can happen without those discouragements."
                )
                
                // Big Picture
                SectionBlock(
                    title: "A Fragmented Society",
                    text: "In our current era, people are constantly moving to new cities, jobs, life stages, and circles—sometimes even every few years.\n\nWhile this nomadic lifestyle brings valuable exposure to different cultures and geographic terrains, it comes at a piercing cost: the abiltiy to build and maintain deep and lasting relationships with people who will, with time, know us fully to the core and walk through life with us.\n\nThis type of good community takes time and presence to build. It is a commitment that is at odds with a lifestyle of constant movement and surface-level interactions. We want to see you connect with the people who call you out when you’re making a mistak, hold your hand through struggles like grief, addiction, or failure, and celebrate with you in areas of wildest joy.\n\nBy simplifying travel and hosting, Freebnb increases the frequency of real-life interactions with loved ones, helping strengthen scattered acquaintenceships into real, thriving relationships."
                )
                
                // Future Work
                SectionBlock(
                    title: "Beyond Friends and Family (Coming Soon)",
                    text: "Freebnb will expand beyond personal networks. Soon, hosts will be able to offer their spaces (such as cabins, vacation homes, or anything in between) to nonprofits, traveling volunteers, community groups, and individuals in transitional situations."
                )
                
                SectionBlock(
                    title: "Equipment Share (Coming Soon)",
                    text: "Freebnb will soon allow you to share items (like small appliances) with your local community. Similar to how you connect with people for stays, you’ll be able to see who’s open to lending or borrowing, making it easy to match with others and share what you have."
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

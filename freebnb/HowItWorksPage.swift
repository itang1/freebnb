//
//  HowItWorksPage.swift
//  freebnb
//
//  Created by Irene Tang on 4/3/26.
//

import SwiftUI

struct HowItWorksPage: View {
    private let guestSteps: [(title: String, detail: String)] = [
        (
            "Browse Listings",
            "Look through available guest rooms from people you know. Filter by amenities, location, and dates."
        ),
        (
            "Request a Stay",
            "Send a stay request with your dates and a short message to the host."
        ),
        (
            "Get Confirmed",
            "The host reviews your request and confirms. You'll get all the details you need for your visit."
        ),
        (
            "Pack and Go",
            "Show up on time, follow house rules, and enjoy your stay."
        ),
        (
            "Leave a Thank You",
            "After your stay, send a thank-you message."
        )
    ]

    private let hostSteps: [(title: String, detail: String)] = [
        (
            "Create a Listing",
            "Describe your guest room, set your availability, and specify any house rules or limits."
        ),
        (
            "Approve Guests",
            "Your listing is only visible to people you've approved. You control who can see and request stays."
        ),
        (
            "Review Requests",
            "When someone wants to stay, you'll get a notification. Accept or decline on your own terms."
        ),
        (
            "Host Your Guest",
            "Welcome them in, show them around, and let them know how things work in your home."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
                Divider()
                    .padding(.vertical, 8)
                
                // Guest section
                Text("For Guests")
                    .font(.title2)
                    .fontWeight(.bold)

                ForEach(Array(guestSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, title: step.title, detail: step.detail)
                }

                Divider()
                    .padding(.vertical, 8)

                // Host section
                Text("For Hosts")
                    .font(.title2)
                    .fontWeight(.bold)

                ForEach(Array(hostSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, title: step.title, detail: step.detail)
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.creamWhite)
        .navigationTitle("How It Works")
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.mintGreen.opacity(0.2))
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: 40, height: 40)
                Text("\(number)")
                    .font(.headline)
//                    .foregroundColor(.mintGreen)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                }
                Text(detail)
                    .font(.subheadline)
            }
        }
    }
}

#Preview {
    NavigationStack {
        HowItWorksPage()
    }
}

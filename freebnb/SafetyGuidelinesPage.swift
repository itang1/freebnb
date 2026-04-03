//
//  SafetyGuidelinesPage.swift
//  freebnb
//
//  Created by Irene Tang on 4/3/26.
//

import SwiftUI

struct SafetyGuidelinesPage: View {
    private let guidelines: [(icon: String, title: String, detail: String)] = [
        (
            "person.2.fill",
            "Only Stay with People You Know",
            "FreeBNB is designed for stays with friends, family, and trusted connections."
        ),
        (
            "bubble.left.and.bubble.right.fill",
            "Communicate Clearly",
            "Discuss expectations before your stay: arrival time, house rules, shared spaces, and anything you need to know."
        ),
        (
            "lock.shield.fill",
            "Trust Your Instincts",
            "If something feels off, whether before or during a stay, it's okay to change plans. Your comfort and safety come first."
        ),
        (
            "mappin.and.ellipse",
            "Share Your Plans",
            "Let someone you trust know where you're staying, when you're arriving, and when you expect to leave."
        ),
        (
            "hand.raised.fill",
            "Respect Boundaries",
            "Both guests and hosts have the right to set limits. If a host says no guests after 10pm or no shoes indoors, respect that. If you're uncomfortable with a rule, talk about it."
        ),
        (
            "exclamationmark.triangle.fill",
            "Know When to Leave",
            "If you ever feel unsafe, you can leave at any time. No stay is worth compromising your well-being. Have a backup plan."
        ),
        (
            "cross.case.fill",
            "Emergency Contacts",
            "Keep local emergency numbers handy. In the US, dial 911 for emergencies. Know where the nearest hospital or urgent care is."
        ),
        (
            "allergens.fill",
            "Disclose Allergies and Needs",
            "If you have allergies, medical needs, or accessibility requirements, let your host know ahead of time so they can prepare."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your safety matters. These guidelines help both guests and hosts have a positive experience.")
                    .font(.subheadline)
                    .padding(.bottom, 4)

                ForEach(Array(guidelines.enumerated()), id: \.offset) { _, guideline in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: guideline.icon)
                            .font(.title3)
                            .foregroundColor(.mintGreen)
                            .frame(width: 30, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(guideline.title)
                                .font(.headline)
                            Text(guideline.detail)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.creamWhite)
        .navigationTitle("Safety Guidelines")
    }
}

#Preview {
    NavigationStack {
        SafetyGuidelinesPage()
    }
}

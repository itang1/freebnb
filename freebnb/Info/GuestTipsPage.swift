//
//  GuestTipsPage.swift
//  freebnb
//

import SwiftUI

struct GuestTipsPage: View {
    private let tips: [(icon: String, title: String, detail: String)] = [
        (
            "message.fill",
            "Communicate Early and Often",
            "Confirm your arrival and departure times ahead of your stay. Let your host know if plans change, even small delays."
        ),
        (
            "gift.fill",
            "Bring a Small Gift (Optional/Cultural)",
            "A treat, a handwritten note, or something from your hometown goes a long way. It doesn't have to be expensive, just thoughtful."
        ),
        (
            "bed.double.fill",
            "Keep Your Space Tidy",
            "Make your bed, keep your belongings organized, and leave the guest room as clean as you found it."
        ),
        (
            "sink.fill",
            "Clean Up After Yourself",
            "Wash your dishes promptly, wipe down counters, and don't leave messes in shared spaces like the kitchen or bathroom."
        ),
        (
            "list.clipboard.fill",
            "Follow House Rules",
            "If the host has preferences like shoes off at the door, quiet hours, or pet boundaries, respect them without being asked twice."
        ),
        (
            "moon.zzz.fill",
            "Be Mindful of Noise",
            "Keep volume low, especially early in the morning and late at night. Use headphones for music and videos."
        ),
        (
            "hand.raised.fill",
            "Respect Privacy and Space",
            "Your host has their own routine. Give them breathing room and don't expect to be entertained around the clock."
        ),
        (
            "bolt.batteryblock.fill",
            "Be Conscious of Utilities",
            "Turn off lights when you leave a room, take reasonable showers, and don't crank the thermostat without asking."
        ),
        (
            "cart.fill",
            "Offer to Chip In",
            "Offer to help with groceries, cook a meal, or pick up takeout. Don't treat a free stay as an all-inclusive resort."
        ),
        (
            "heart.fill",
            "Express Gratitude",
            "A sincere thank-you, in person and in a follow-up message, means more than you think. Let your host know you appreciate their generosity."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A little courtesy goes a long way when someone opens their home to you.")
                    .font(.subheadline)
                    .padding(.bottom, 4)

                ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: tip.icon)
                            .font(.title3)
                            .foregroundColor(Color.accent)
                            .frame(width: 30, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(tip.title)
                                .font(.headline)
                            Text(tip.detail)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.primaryBackground)
        .navigationTitle("Guest Tips")
    }
}

#Preview {
    NavigationStack {
        GuestTipsPage()
    }
}

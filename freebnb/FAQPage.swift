//
//  FAQPage.swift
//  freebnb
//
//  Created by Irene Tang on 4/3/26.
//

import SwiftUI

struct FAQItem: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

struct FAQPage: View {
    private let faqs: [FAQItem] = [
        FAQItem(
            question: "Is FreeBNB really free?",
            answer: "Yes, completely. There are no booking fees, service charges, or hidden costs. Hosts share their space voluntarily."
        ),
        FAQItem(
            question: "Who can see my listing?",
            answer: "Only people you've approved. Your listing is never visible to the general public or to strangers."
        ),
        FAQItem(
            question: "How is FreeBNB different from Couchsurfing or other home-sharing platforms?",
            answer: "FreeBNB is built around trust, not strangers. Unlike Couchsurfing or similar platforms where you open your home to the public, FreeBNB is invite-only: you only see listings from people already in your network of trusted contacts. There's no public marketplace, no reviews from strangers, and no algorithm matching you with random people. Your guests are people you already know or are at most a step removed from, not strangers you met online."
        ),
        FAQItem(
            question: "How long can I stay?",
            answer: "Each host sets their own maximum stay length. You'll see this on the listing. Please respect the limit."
        ),
        FAQItem(
            question: "Can I bring my pet?",
            answer: "It depends on the host. Check the listing for whether guest pets are allowed. Some hosts also have their own pets on the premises."
        ),
        FAQItem(
            question: "What if I need to cancel?",
            answer: "Let your host know as soon as possible. There are no cancellation fees, but canceling last-minute is inconsiderate. Communicate early."
        ),
        FAQItem(
            question: "What should I bring?",
            answer: "Check the listing to see what's provided (pillows, towels, toiletries). When in doubt, bring your own basics and a small thank-you gift for your host."
        ),
        FAQItem(
            question: "Can I be both a guest and a host?",
            answer: "Absolutely. Many FreeBNB users both host visitors and stay at others' places. It's a community built on mutual generosity."
        ),
        FAQItem(
            question: "What if something goes wrong during my stay?",
            answer: "Talk to your host first. Most issues can be resolved with a conversation. If you feel unsafe, leave and contact someone you trust. See our Safety Guidelines for more."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(faqs) { faq in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(faq.question)
                            .font(.headline)
                        Text(faq.answer)
                            .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: 600)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.creamWhite)
        .navigationTitle("FAQ")
    }
}

#Preview {
    NavigationStack {
        FAQPage()
    }
}

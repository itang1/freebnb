//
//  OnboardingPage.swift
//  freebnb
//

import SwiftUI

struct OnboardingPage: View {
    @Binding var isPresented: Bool
    /// Called when the user answers the hosting step with "List My Place".
    /// The parent presents the create-listing flow after this sheet dismisses;
    /// doing it here would race the dismissal animation.
    var onChooseHost: () -> Void = {}
    @State private var currentPage = 0

    private struct Slide {
        let icon: String
        let title: String
        let body: String
    }

    // One slide per differentiator, each distinct: the promise (free + trusted),
    // trust made visible (you always know your host), privacy (no contacts grab,
    // which is literally true since the network is built from friends, never the
    // address book), then how a stay works.
    private let slides: [Slide] = [
        Slide(
            icon: "house.lodge.fill",
            title: "Stay with people you trust",
            body: "A free place to crash with friends and friends of friends. No strangers, no booking fees."
        ),
        Slide(
            icon: "person.2.fill",
            title: "You'll always know your host",
            body: "You only see places from people in your network, and hosts choose who can view and request their space. You never request a stay from a stranger."
        ),
        Slide(
            icon: "lock.shield.fill",
            title: "Your circle stays yours",
            body: "Your network is built only from people you choose to connect with. We never scrape or upload your contacts."
        ),
        Slide(
            icon: "calendar.badge.checkmark",
            title: "Request and go",
            body: "Find a place and send a request with your dates. If your host says yes, pack your bags."
        )
    ]

    /// The hosting-intent ask sits after the walkthrough slides as its own page.
    /// Hosts are the scarce side of the network, so the one question worth
    /// asking before the user ever sees a (possibly thin) feed is whether they
    /// have a couch to offer.
    private var isHostStep: Bool { currentPage == slides.count }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accent.opacity(0.15), .primaryBackground, Color.accent.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide).tag(index)
                    }
                    hostStepView.tag(slides.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                VStack(spacing: 12) {
                    Button(action: advance) {
                        Text(isHostStep ? "List My Place" : "Next")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accent)
                            .foregroundColor(.onAccent)
                            .cornerRadius(12)
                    }
                    // Fixed-height slot keeps layout stable across pages: Skip on
                    // the walkthrough, the guest-only answer on the hosting step.
                    Group {
                        if isHostStep {
                            Button("I'm just looking for now") { isPresented = false }
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        } else {
                            Button("Skip") { isPresented = false }
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .frame(height: 20)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 36)
            }
        }
    }

    private var hostStepView: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.15))
                    .frame(width: 140, height: 140)
                Image(systemName: "sofa.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Got a couch or a guest room?")
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text("To one of your friends, that's a free trip. Only friends you approve can ever see your place.")
                    .font(.body)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.15))
                    .frame(width: 140, height: 140)
                Image(systemName: slide.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(slide.body)
                    .font(.body)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private func advance() {
        if isHostStep {
            isPresented = false
            onChooseHost()
        } else {
            withAnimation { currentPage += 1 }
        }
    }
}

#Preview {
    OnboardingPage(isPresented: .constant(true))
}

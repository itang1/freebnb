//
//  OnboardingPage.swift
//  freebnb
//

import SwiftUI

struct OnboardingPage: View {
    @Binding var isPresented: Bool
    /// Called on "List My Place"; the parent presents create-listing after this sheet dismisses (doing it
    /// here races the animation).
    var onChooseHost: () -> Void = {}
    @State private var currentPage = 0

    private typealias Slide = ThemeCopy.Onboarding.Slide

    // One slide per differentiator: the promise (free + trusted), trust made visible, privacy (no contacts
    // grab; the network is friends, not the address book), then how a stay works. Copy lives in ThemeCopy.
    private let slides = ThemeCopy.Onboarding.slides

    /// The hosting-intent ask follows the walkthrough: hosts are the scarce side, so the question to ask
    /// before a possibly thin feed is whether they have a couch to offer.
    private var isHostStep: Bool { currentPage == slides.count }

    var body: some View {
        ZStack {
            LagoonBackdrop()

            // Water along the bottom edge, rolling under the buttons.
            VStack {
                Spacer()
                Shoreline(height: 90, frontColor: .primaryBackground)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide).tag(index)
                    }
                    hostStepView.tag(slides.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                // A backing pill so the page dots read on pale sand, not just over dark photos.
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 12) {
                    Button(action: advance) {
                        Text(isHostStep ? ThemeCopy.Onboarding.hostAction : ThemeCopy.Onboarding.next)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LagoonButtonStyle(kind: isHostStep ? .callToAction : .primary))
                    // Fixed-height slot keeps layout stable: Skip on the walkthrough, the guest-only answer
                    // on the hosting step.
                    Group {
                        if isHostStep {
                            Button(ThemeCopy.Onboarding.justLooking) { isPresented = false }
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        } else {
                            Button(ThemeCopy.Onboarding.skip) { isPresented = false }
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

            EmptyStateMedallion(systemImage: ThemeCopy.Onboarding.hostIcon)
                .scaleEffect(1.2)

            VStack(spacing: 12) {
                Text(ThemeCopy.Onboarding.hostTitle)
                    .font(.display(.title))
                    .multilineTextAlignment(.center)
                Text(ThemeCopy.Onboarding.hostBody)
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

            // The same tide pool as the empty states, a touch larger: the walkthrough is a postcard tour.
            EmptyStateMedallion(systemImage: slide.icon)
                .scaleEffect(1.2)

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.display(.title))
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

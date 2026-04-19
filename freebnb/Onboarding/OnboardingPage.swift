//
//  OnboardingPage.swift
//  freebnb
//

import SwiftUI

struct OnboardingPage: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private struct Slide {
        let icon: String
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(
            icon: "house.lodge.fill",
            title: "Welcome to FreeBNB",
            body: "Stay with people you know, for free. No booking fees, no strangers."
        ),
        Slide(
            icon: "person.2.fill",
            title: "People You Know",
            body: "You only see listings from people in your network. Hosts control who can view and request their space."
        ),
        Slide(
            icon: "calendar.badge.checkmark",
            title: "Request a Stay",
            body: "Find a listing, send a request with your dates, and your host confirms. Pack your bags and go."
        )
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("AppTeal").opacity(0.15), .creamWhite, Color("AppTeal").opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                VStack(spacing: 12) {
                    Button(action: advance) {
                        Text(currentPage < slides.count - 1 ? "Next" : "Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color("AppTeal"))
                            .flippedPrimaryColor()
                            .cornerRadius(12)
                    }
                    // Fixed-height slot keeps layout stable when Skip disappears
                    Group {
                        if currentPage < slides.count - 1 {
                            Button("Skip") { isPresented = false }
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 20)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 36)
            }
        }
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color("AppTeal").opacity(0.15))
                    .frame(width: 140, height: 140)
                Image(systemName: slide.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color("AppTeal"))
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(slide.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private func advance() {
        if currentPage < slides.count - 1 {
            withAnimation { currentPage += 1 }
        } else {
            isPresented = false
        }
    }
}

#Preview {
    OnboardingPage(isPresented: .constant(true))
}

//
//  AgeGateView.swift
//  freebnb
//

import SwiftUI

struct AgeGateView: View {
    @AppStorage(UserDefaultsKey.ageGateAccepted) private var ageGateAccepted = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 64))
                    .foregroundColor(Color.accent)

                Text("You must be 18 or older")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("FreeBNB connects trusted adults for free home stays. By continuing, you confirm that you are at least 18 years old.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Button {
                    ageGateAccepted = true
                } label: {
                    Text("I am 18 or older")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .cornerRadius(14)
                }
                .accessibilityIdentifier("ageGate.continueButton")

                Text("If you are under 18, please close the app.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(Color.primaryBackground.ignoresSafeArea())
    }
}

#Preview {
    AgeGateView()
}

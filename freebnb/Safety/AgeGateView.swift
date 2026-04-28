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
                    .foregroundColor(Color.appTeal)

                Text("You must be 18 or older")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("FreeBNB connects trusted adults for free home stays. By continuing, you confirm that you are at least 18 years old.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Button {
                    ageGateAccepted = true
                } label: {
                    Text("I am 18 or older — Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.appTeal)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }

                Text("If you are under 18, please close the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(Color.creamWhite.ignoresSafeArea())
    }
}

#Preview {
    AgeGateView()
}

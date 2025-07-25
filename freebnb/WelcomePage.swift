//
//  WelcomePage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI

struct WelcomePage: View {
    var onEnter: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Welcome to FreeBNB")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("The guest rooms of people you know")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button(action: onEnter) {
                Text("Enter")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }
}

#Preview {
    WelcomePage(onEnter: {})
}

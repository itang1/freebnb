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
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    .creamWhite,
                    .seafoamBlue
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack {
                Spacer()
                
                VStack(spacing: 20) {
                    Text("Welcome to FreeBNB")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                    
                    Text("The guest rooms of people you know")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Image(systemName: "house.lodge.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .symbolRenderingMode(.palette)
                        .foregroundColor(.mintGreen)
                }
                
                Spacer()
                
                Button(action: onEnter) {
                    Text("Enter")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.mintGreen)
                        .flippedPrimaryColor()
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                .padding(.bottom, 20)
            }

        }
    }
}

#Preview {
    WelcomePage(onEnter: {})
}

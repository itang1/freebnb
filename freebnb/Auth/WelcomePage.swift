//
//  WelcomePage.swift
//  freebnb
//

import SwiftUI
import AuthenticationServices

struct WelcomePage: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.appTeal.opacity(0.15),
                    .creamWhite,
                    Color.appTeal.opacity(0.3)
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
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Image(systemName: "house.lodge.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 250, height: 200)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.appTeal)
                        .accessibilityHidden(true)
                }

                Spacer()

                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        authManager.prepareAppleSignInRequest(request)
                    } onCompletion: { result in
                        authManager.handleAuthorization(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .disabled(authManager.isLoading)

                    if authManager.isLoading {
                        ProgressView()
                            .tint(Color.appTeal)
                    } else {
                        Button("Continue as Guest") {
                            authManager.continueAsGuest()
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }

                    if let error = authManager.authError,
                       let description = error.errorDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                }
                .padding(.bottom, 20)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

#Preview {
    NavigationStack {
        WelcomePage()
            .environment(AuthManager())
    }
}

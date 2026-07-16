//
//  AuthProviderButtons.swift
//  freebnb
//

import AuthenticationServices
import SwiftUI

/// The Apple / Google / email buttons shared by the welcome screen and the
/// guest-to-account "Create Account" screen. `appleButtonType` and the two
/// labels flip between sign-in and sign-up phrasing; the underlying
/// `AuthManager` calls decide for themselves whether to link an active guest
/// session or start a fresh one.
struct AuthProviderButtons: View {
    @Environment(AuthManager.self) private var authManager

    let appleButtonType: SignInWithAppleButton.Label
    let googleLabel: String
    let googleAccessibilityID: String
    let emailLabel: String
    let emailAccessibilityID: String
    let onEmailTap: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            SignInWithAppleButton(appleButtonType) { request in
                authManager.prepareAppleSignInRequest(request)
            } onCompletion: { result in
                authManager.handleAuthorization(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .cornerRadius(12)
            .padding(.horizontal)
            .disabled(authManager.isLoading)

            Button {
                authManager.signInWithGoogle()
            } label: {
                HStack(spacing: 8) {
                    Text("G")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundColor(Color(red: 0.26, green: 0.52, blue: 0.96))
                    Text(googleLabel)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.white)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                )
            }
            .padding(.horizontal)
            .disabled(authManager.isLoading)
            .accessibilityIdentifier(googleAccessibilityID)

            Button(action: onEmailTap) {
                Label(emailLabel, systemImage: "envelope.fill")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accent.opacity(0.12))
                    .foregroundColor(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal)
            .disabled(authManager.isLoading)
            .accessibilityIdentifier(emailAccessibilityID)
        }
    }
}

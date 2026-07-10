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
                    Color.accent.opacity(0.15),
                    .primaryBackground,
                    Color.accent.opacity(0.3)
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
                        .foregroundStyle(Color.accent)
                        .accessibilityHidden(true)
                }

                Spacer()

                VStack(spacing: 16) {
                    // Quick sign-in into fixed, pre-seeded accounts for local
                    // development — never a real user's path. Compile- and
                    // emulator-gated so these credentials can never reach the
                    // production project (see AuthManager.signInWithEmail).
                    #if DEBUG
                    if EmulatorEnvironment.isActive {
                        quickSignInSection
                        dividerRow
                    }
                    #endif

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
                            .tint(Color.accent)
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
        .toolbar(.hidden, for: .navigationBar)
    }

    #if DEBUG
    private var quickSignInSection: some View {
        VStack(spacing: 8) {
            Text("Debug quick sign-in")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 10) {
                QuickSignInButton(
                    label: "Sign in as guest",
                    systemImage: "person.fill.questionmark",
                    accessibilityID: "welcome.guestSignInButton"
                ) {
                    authManager.signInWithEmail("guest@freebnb.test", password: "***REDACTED***")
                }

                QuickSignInButton(
                    label: "Sign in as devna",
                    systemImage: "hammer.fill",
                    accessibilityID: "welcome.devnaSignInButton"
                ) {
                    authManager.signInWithEmail("dev@freebnb.test", password: "***REDACTED***")
                }
            }
            .disabled(authManager.isLoading)
        }
        .padding(.horizontal)
    }

    private var dividerRow: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack { Divider() }
        }
        .padding(.horizontal)
    }
    #endif
}

#if DEBUG
/// A compact, capsule-shaped secondary button for the DEBUG-only quick
/// sign-in accounts — visually distinct from the primary Sign in with Apple
/// button below it, so it never reads as the "real" way to sign in.
private struct QuickSignInButton: View {
    let label: String
    let systemImage: String
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accent.opacity(0.12))
            .foregroundColor(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .accessibilityIdentifier(accessibilityID)
    }
}
#endif

#Preview {
    NavigationStack {
        WelcomePage()
            .environment(AuthManager())
    }
}

//
//  CreateAccountPage.swift
//  freebnb
//

import SwiftUI

/// Guest-to-account upgrade, pushed from the Profile tab. Kept off the
/// Profile page itself so three sign-up buttons don't dominate a screen
/// that's mostly settings; this gets its own scroll and its own moment.
///
/// Every path here links the active anonymous session instead of starting a
/// fresh one (see `AuthManager.handleAuthorization`, `signInWithGoogle`, and
/// `register(withEmail:password:displayName:)`), so guest data carries over
/// no matter which provider the guest picks.
struct CreateAccountPage: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @State private var showEmailAuth = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(Color.accent)
                        .padding(.top, 24)

                    Text("Create an account")
                        .font(.title2).fontWeight(.semibold)

                    Text("Save your info so it's there next time. Everything from your guest session (messages, bookmarks, and more) carries over.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                AuthProviderButtons(
                    appleButtonType: .signUp,
                    googleLabel: "Sign up with Google",
                    googleAccessibilityID: "createAccount.googleSignInButton",
                    emailLabel: "Sign up with email",
                    emailAccessibilityID: "createAccount.emailAuthButton"
                ) {
                    showEmailAuth = true
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                    Text("FreeBNB never sees or stores your password. Sign-in is handled entirely by Apple or Google.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

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
                        .padding(.horizontal, 32)
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView(initialMode: .register)
                .environment(authManager)
        }
        // The guest session upgrades in place; once it's no longer anonymous
        // there's nothing left to do on this screen but close it.
        .onChange(of: authManager.authMethod) { _, method in
            if method != .guest { dismiss() }
        }
    }
}

#Preview {
    NavigationStack {
        CreateAccountPage()
            .previewEnvironment()
    }
}

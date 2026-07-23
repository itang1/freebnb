//
//  WelcomePage.swift
//  freebnb
//

import SwiftUI

struct WelcomePage: View {
    @Environment(AuthManager.self) private var authManager
    @State private var showEmailAuth = false

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

                    Text("A free place to stay with people you know.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Image(systemName: "house.lodge.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 150)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.accent)
                        .accessibilityHidden(true)
                }

                Spacer()

                VStack(spacing: 16) {
                    trustStrip

                    #if DEBUG
                    if EmulatorEnvironment.isActive {
                        quickSignInSection
                        dividerRow
                    }
                    #endif

                    AuthProviderButtons(
                        appleButtonType: .signIn,
                        googleLabel: "Sign in with Google",
                        googleAccessibilityID: "welcome.googleSignInButton",
                        emailLabel: "Continue with email",
                        emailAccessibilityID: "welcome.emailAuthButton"
                    ) {
                        showEmailAuth = true
                    }

                    if authManager.isLoading {
                        ProgressView()
                            .tint(Color.accent)
                    }

                    if let error = authManager.authError,
                       let description = error.errorDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                }
                .padding(.bottom, 20)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView()
                .environment(authManager)
        }
    }

    // MARK: - Trust strip

    private var trustStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            trustRow(
                icon: "person.2.fill",
                title: "Only people you know",
                subtitle: "No strangers, ever."
            )
            trustRow(
                icon: "tag.slash.fill",
                title: "Always free",
                subtitle: "No booking fees."
            )
            trustRow(
                icon: "lock.shield.fill",
                title: "Your circle stays yours",
                subtitle: "We never upload your contacts."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
    }

    private func trustRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    private let quickSignInColumns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    private var quickSignInSection: some View {
        VStack(spacing: 8) {
            Text("Debug quick sign-in")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)

            // The whole seeded cast, three across. Bounded in a ScrollView so a
            // long roster never pushes the real Apple/Google buttons off screen.
            ScrollView {
                LazyVGrid(columns: quickSignInColumns, spacing: 10) {
                    ForEach(TestProfile.all) { profile in
                        QuickSignInButton(
                            label: profile.displayName,
                            systemImage: profile.systemImage,
                            accessibilityID: profile.accessibilityID(surface: "welcome")
                        ) {
                            authManager.signInWithEmail(profile.email, password: profile.password)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 220)
            .disabled(authManager.isLoading)
        }
        .padding(.horizontal)
    }

    private var dividerRow: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundColor(.secondaryText)
            VStack { Divider() }
        }
        .padding(.horizontal)
    }
    #endif
}

#if DEBUG
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
            .previewEnvironment()
    }
}

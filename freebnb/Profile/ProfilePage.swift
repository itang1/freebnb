//
//  ProfilePage.swift
//  freebnb
//

import SwiftUI
import AuthenticationServices

struct ProfilePage: View {
    @Environment(AuthManager.self) private var authManager
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("appearance") private var appearance = "system"

    @Environment(\.openURL) private var openURL
    @State private var showEditName = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                profileHeader
                    .padding(.bottom, 8)

                Divider().padding(.vertical, 8)

                if authManager.authMethod == .guest {
                    guestSignUpSection
                    Divider().padding(.vertical, 8)
                } else {
                    sectionLabel("Account")
                    VStack(spacing: 0) {
                        SettingsRow(icon: "pencil", label: "Edit Name", chevron: true,
                                    trailingText: authManager.userName.isEmpty ? nil : authManager.userName) {
                            showEditName = true
                        }
                        if !authManager.userEmail.isEmpty {
                            rowDivider
                            SettingsRow(icon: "envelope", label: "Email",
                                        trailingText: authManager.userEmail)
                        }
                    }
                    .sectionCard()
                    .padding(.bottom, 20)
                }

                sectionLabel("Preferences")
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell")
                            .frame(width: 28)
                            .foregroundColor(Color.appTeal)
                        Text("Notifications")
                        Spacer()
                        Toggle("", isOn: $notificationsEnabled)
                            .labelsHidden()
                            .tint(Color.appTeal)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    rowDivider

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.lefthalf.filled")
                                .frame(width: 28)
                                .foregroundColor(Color.appTeal)
                            Text("Appearance")
                        }
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .sectionCard()
                .padding(.bottom, 20)

                sectionLabel("About")
                VStack(spacing: 0) {
                    SettingsRow(icon: "number", label: "Version", trailingText: appVersion)
                    rowDivider
                    SettingsRow(icon: "hand.raised", label: "Privacy Policy", chevron: true) {
                        if let url = URL(string: "https://freebnb.app/privacy") { openURL(url) }
                    }
                    rowDivider
                    SettingsRow(icon: "doc.text", label: "Terms of Service", chevron: true) {
                        if let url = URL(string: "https://freebnb.app/terms") { openURL(url) }
                    }
                }
                .sectionCard()
                .padding(.bottom, 20)

                if authManager.authMethod != .guest {
                    VStack(spacing: 10) {
                        Button(role: .destructive) {
                            authManager.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.08))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Account")
                                .font(.subheadline)
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 16)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle("Profile")
        .sheet(isPresented: $showEditName) {
            EditNameSheet().environment(authManager)
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) { authManager.deleteAccount() }
        } message: {
            Text("This permanently removes your account and all saved data. It cannot be undone.")
        }
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.appTeal.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: authManager.authMethod == .guest ? "person.slash" : "person.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundColor(Color.appTeal)
            }
            .padding(.top, 16)

            VStack(spacing: 4) {
                if authManager.authMethod == .guest {
                    Text("Guest")
                        .font(.title2).fontWeight(.semibold)
                    Text("Browsing without an account")
                        .font(.subheadline).foregroundColor(.secondary)
                } else {
                    Text(authManager.userName.isEmpty ? "No Name" : authManager.userName)
                        .font(.title2).fontWeight(.semibold)
                        .foregroundColor(authManager.userName.isEmpty ? .secondary : .primary)
                    if !authManager.userEmail.isEmpty {
                        Text(authManager.userEmail)
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Label(authMethodLabel, systemImage: authMethodIcon)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appTeal.opacity(0.12))
                    .foregroundColor(Color.appTeal)
                    .clipShape(Capsule())
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Guest sign-up section

    private var guestSignUpSection: some View {
        VStack(spacing: 12) {
            Text("Create an account to save your info")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SignInWithAppleButton(.signUp) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                authManager.handleAuthorization(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .cornerRadius(12)
            .padding(.horizontal)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                Text("FreeBNB never sees or stores your password. Sign-in is handled entirely by Apple.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 4)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var authMethodLabel: String {
        switch authManager.authMethod {
        case .apple:  return "Signed in with Apple"
        case .guest:  return "Guest"
        case .none:   return ""
        }
    }

    private var authMethodIcon: String {
        switch authManager.authMethod {
        case .apple:  return "apple.logo"
        case .guest:  return "person.slash"
        case .none:   return "questionmark"
        }
    }
}

// MARK: - Section card modifier

private extension View {
    func sectionCard() -> some View {
        self
            .background(Color.secondary.opacity(0.07))
            .cornerRadius(14)
            .padding(.horizontal)
    }
}

// MARK: - Settings row

private struct SettingsRow: View {
    let icon: String
    let label: String
    var chevron: Bool = false
    var trailingText: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundColor(Color.appTeal)
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                if let text = trailingText {
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .disabled(action == nil && !chevron)
    }
}

// MARK: - Edit name sheet

private struct EditNameSheet: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit Name")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        authManager.updateName(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              name.trimmingCharacters(in: .whitespaces) == authManager.userName)
                }
            }
            .onAppear { name = authManager.userName }
        }
    }
}

#Preview {
    NavigationStack {
        ProfilePage()
            .environment(AuthManager())
    }
}

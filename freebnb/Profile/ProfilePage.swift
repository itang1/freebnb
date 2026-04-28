//
//  ProfilePage.swift
//  freebnb
//

import SwiftUI
import AuthenticationServices
import UserNotifications

struct ProfilePage: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @AppStorage(UserDefaultsKey.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(UserDefaultsKey.appearance) private var appearance = "system"

    @Environment(\.openURL) private var openURL
    @State private var showEditName = false
    @State private var showDeleteConfirm = false
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined

    private static let privacyURL = URL(string: "https://freebnb.app/privacy")!
    private static let termsURL   = URL(string: "https://freebnb.app/terms")!

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
                                    trailingText: userProfileStore.displayName) {
                            showEditName = true
                        }
                        if !authManager.userEmail.isEmpty {
                            rowDivider
                            SettingsRow(icon: "envelope", label: "Email",
                                        trailingText: authManager.userEmail)
                        }
                        rowDivider
                        NavigationLink {
                            FriendsPage()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.2")
                                    .frame(width: 28)
                                    .foregroundColor(Color.appTeal)
                                Text("Friends")
                                    .foregroundColor(.primary)
                                Spacer()
                                let count = friendStore.friendEdges.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                if friendStore.pendingCount > 0 {
                                    Text("\(friendStore.pendingCount)")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.appTeal)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
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
                        Toggle("", isOn: Binding(
                            get: { notificationsEnabled && notifAuthStatus != .denied },
                            set: { newValue in handleNotificationToggle(newValue) }
                        ))
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
                        openURL(Self.privacyURL)
                    }
                    rowDivider
                    SettingsRow(icon: "doc.text", label: "Terms of Service", chevron: true) {
                        openURL(Self.termsURL)
                    }
                }
                .sectionCard()
                .padding(.bottom, 20)

                #if DEBUG
                sectionLabel("Dev")
                VStack(spacing: 0) {
                    SettingsRow(icon: "envelope", label: "Sign in as dev@freebnb.test") {
                        authManager.signInWithEmail("dev@freebnb.test", password: "***REDACTED***")
                    }
                }
                .sectionCard()
                .padding(.bottom, 20)
                #endif

                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        authManager.signOut()
                    } label: {
                        Label(
                            authManager.authMethod == .guest ? "Sign Out (End Guest Session)" : "Sign Out",
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.08))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                    }

                    if authManager.authMethod != .guest {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Account")
                                .font(.subheadline)
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .padding(.top, 16)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle("Profile")
        .task { await refreshNotifStatus() }
        .sheet(isPresented: $showEditName) {
            EditNameSheet()
                .environment(userProfileStore)
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await authManager.deleteAccount() }
            }
        } message: {
            Text("This permanently removes your account and all saved data. It cannot be undone. Sign in with Apple will prompt again to confirm.")
        }
    }

    // MARK: - Notifications

    private func refreshNotifStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifAuthStatus = settings.authorizationStatus
        if settings.authorizationStatus == .denied {
            notificationsEnabled = false
        }
    }

    private func handleNotificationToggle(_ enabled: Bool) {
        if !enabled {
            notificationsEnabled = false
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                notificationsEnabled = granted
                notifAuthStatus = granted ? .authorized : .denied
            case .authorized, .provisional, .ephemeral:
                notificationsEnabled = true
                notifAuthStatus = .authorized
            case .denied:
                // OS has blocked notifications; direct user to Settings
                notificationsEnabled = false
                notifAuthStatus = .denied
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    await MainActor.run { openURL(url) }
                }
            @unknown default:
                notificationsEnabled = false
            }
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
                    Text(userProfileStore.displayName ?? "No Name")
                        .font(.title2).fontWeight(.semibold)
                        .foregroundColor(userProfileStore.displayName == nil ? .secondary : .primary)
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
                authManager.prepareAppleSignInRequest(request)
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
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .disabled(isSaving)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Name")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving ||
                                  name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  name.trimmingCharacters(in: .whitespaces) == userProfileStore.displayName)
                }
            }
            .onAppear { name = userProfileStore.displayName ?? "" }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try await userProfileStore.updateDisplayName(trimmed)
            try await homeStore.updateHostName(for: authManager.userID, newName: trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        ProfilePage()
            .environment(AuthManager())
            .environment(UserProfileStore())
            .environment(StayRequestStore())
            .environment(HomeStore())
    }
}

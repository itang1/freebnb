//
//  ProfilePage.swift
//  freebnb
//

import SwiftUI
import UserNotifications

struct ProfilePage: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @AppStorage(UserDefaultsKey.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(UserDefaultsKey.appearance) private var appearance = "system"

    @State private var showEditName = false
    @State private var showDeleteConfirm = false
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var isExporting = false
    @State private var exportFile: ExportFile?
    @State private var exportError: String?

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
                        // What everyone else sees: reputation, reviews, references.
                        NavigationLink {
                            UserProfilePage(
                                userID: authManager.userID,
                                fallbackName: userProfileStore.displayName ?? "You"
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle")
                                    .frame(width: 28)
                                    .foregroundColor(Color.accent)
                                Text("Your public profile")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }

                        rowDivider

                        SettingsRow(icon: "pencil", label: "Edit Name", chevron: true,
                                    trailingText: userProfileStore.displayName) {
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

                    hostingSection
                }

                sectionLabel("Preferences")
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell")
                            .frame(width: 28)
                            .foregroundColor(Color.accent)
                        Text("Notifications")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { notificationsEnabled && notifAuthStatus != .denied },
                            set: { newValue in handleNotificationToggle(newValue) }
                        ))
                        .labelsHidden()
                        .tint(Color.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    rowDivider

                    NavigationLink {
                        NotificationSettingsPage()
                            .environment(userProfileStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 28)
                                .foregroundColor(Color.accent)
                            Text("What you're notified about")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    rowDivider

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.lefthalf.filled")
                                .frame(width: 28)
                                .foregroundColor(Color.accent)
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

                if authManager.authMethod != .guest {
                    sectionLabel("Your Data")
                    VStack(spacing: 0) {
                        Button {
                            Task { await exportData() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(width: 28)
                                    .foregroundColor(Color.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Export my data")
                                        .foregroundColor(.primary)
                                    Text("Download everything we store about you as JSON.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isExporting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .disabled(isExporting)
                    }
                    .sectionCard()
                    .padding(.bottom, 20)
                }

                sectionLabel("About")
                VStack(spacing: 0) {
                    helpAndInfoRow
                    rowDivider
                    SettingsRow(icon: "number", label: "Version", trailingText: appVersion)
                    rowDivider
                    NavigationLink {
                        MarkdownPage(fileName: "privacy-policy", title: "Privacy Policy")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised")
                                .frame(width: 28)
                                .foregroundColor(Color.accent)
                            Text("Privacy Policy")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    rowDivider
                    NavigationLink {
                        MarkdownPage(fileName: "terms-of-service", title: "Terms of Service")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .frame(width: 28)
                                .foregroundColor(Color.accent)
                            Text("Terms of Service")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
                .sectionCard()
                .padding(.bottom, 20)

                // Only offered when the app is pointed at the Auth emulator, so the
                // seeded credentials are never sent to the production project.
                #if DEBUG
                if EmulatorEnvironment.isActive {
                    sectionLabel("Dev")
                    VStack(spacing: 0) {
                        SettingsRow(icon: "person.fill.questionmark", label: "Sign in as guest",
                                    accessibilityID: "profile.guestSignInButton") {
                            authManager.signInWithEmail("guest@freebnb.test", password: "***REDACTED***")
                        }
                        rowDivider
                        SettingsRow(icon: "hammer.fill", label: "Sign in as devna",
                                    accessibilityID: "profile.devSignInButton") {
                            authManager.signInWithEmail("dev@freebnb.test", password: "***REDACTED***")
                        }
                    }
                    .sectionCard()
                    .padding(.bottom, 20)
                }
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
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Profile")
        .task { await refreshNotifStatus() }
        .sheet(isPresented: $showEditName) {
            EditNameSheet()
                .environment(userProfileStore)
        }
        .sheet(item: $exportFile) { file in
            DataExportShareSheet(url: file.url)
        }
        .alert("Couldn't export data", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            if let exportError { Text(exportError) }
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

    // MARK: - Data export

    private func exportData() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let url = try await userProfileStore.exportDataFile()
            exportFile = ExportFile(url: url)
        } catch {
            exportError = error.localizedDescription
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
            PersonAvatar(
                systemImage: authManager.authMethod == .guest ? "person.slash" : "person.fill",
                size: 100
            )
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
                    .background(Color.accent.opacity(0.12))
                    .foregroundColor(Color.accent)
                    .clipShape(Capsule())
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Guest sign-up section

    private var guestSignUpSection: some View {
        NavigationLink {
            CreateAccountPage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .frame(width: 28)
                    .foregroundColor(Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create an account")
                        .foregroundColor(.primary)
                    Text("Save your info so it's there next time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .sectionCard()
        .accessibilityIdentifier("profile.createAccountButton")
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
        case .google: return "Signed in with Google"
        case .email:  return "Signed in with email"
        case .guest:  return "Guest"
        case .none:   return ""
        }
    }

    private var authMethodIcon: String {
        switch authManager.authMethod {
        case .apple:  return "apple.logo"
        case .google: return "g.circle.fill"
        case .email:  return "envelope.fill"
        case .guest:  return "person.slash"
        case .none:   return "questionmark"
        }
    }
}

// Sections kept out of the main struct body so their lines don't count toward
// SwiftLint's type_body_length; `private` stays file-scoped, so they still see
// the view's environment.
extension ProfilePage {
    // MARK: - Hosting section

    /// Hosting lives on the Stays tab behind a segmented picker, which a would-be
    /// host has no reason to look under. Surface the same page here, where "list
    /// my home" is a natural thing to go looking for.
    var hostingSection: some View {
        Group {
            sectionLabel("Hosting")
            VStack(spacing: 0) {
                NavigationLink {
                    YourListingsPage()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "house")
                            .frame(width: 28)
                            .foregroundColor(Color.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your listings")
                                .foregroundColor(.primary)
                            Text("List your home so friends can request to stay.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .sectionCard()
            .padding(.bottom, 20)
        }
    }

    // MARK: - Help & info row

    /// The former Info tab, folded in here: reference content (guides, FAQ,
    /// safety) is visited too rarely to earn a fifth of the tab bar, but it
    /// still needs a stable, findable home.
    var helpAndInfoRow: some View {
        NavigationLink {
            InfoPage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book")
                    .frame(width: 28)
                    .foregroundColor(Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help & Info")
                        .foregroundColor(.primary)
                    Text("Guides, FAQ, safety, and what's new.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

#Preview {
    NavigationStack {
        ProfilePage()
            .previewEnvironment()
    }
}

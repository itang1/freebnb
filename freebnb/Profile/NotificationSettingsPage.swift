//
//  NotificationSettingsPage.swift
//  freebnb
//
//  Per-category push preferences. These persist to the private profile and are
//  read by the Cloud Functions before a push is sent, so a mute here actually
//  stops the notification server-side and follows the user across devices
//  (feature 37).
//

import SwiftUI

struct NotificationSettingsPage: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @State private var errorMessage: String?

    private var prefs: NotificationPreferences {
        userProfileStore.currentProfile?.effectiveNotificationPrefs ?? NotificationPreferences()
    }

    var body: some View {
        List {
            Section {
                ForEach(NotificationCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        HStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .frame(width: 28)
                                .foregroundColor(Color.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(category.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                            }
                        }
                    }
                    .tint(Color.accent)
                }
            } footer: {
                Text("Turn a category off to stop those push notifications on all your devices. You can still see everything in the app.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.danger)
                }
            }
        }
        .navigationTitle("Notifications")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { prefs.isEnabled(category) },
            set: { newValue in
                let updated = prefs.setting(category, to: newValue)
                Task {
                    do {
                        errorMessage = nil
                        try await userProfileStore.updateNotificationPrefs(updated)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsPage()
            .previewEnvironment()
    }
}

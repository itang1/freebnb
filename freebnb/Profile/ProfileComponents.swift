//
//  ProfileComponents.swift
//  freebnb
//
//  ProfilePage's supporting pieces, split out so the 600-line settings screen
//  and its sheets type-check in parallel.
//

import SwiftUI

// MARK: - Data export share sheet

/// Wraps the exported file URL so it can drive a `.sheet(item:)`.
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// A small sheet presenting the finished export with a ShareLink. Presented
/// programmatically once the async export completes (ShareLink alone can't be
/// triggered from code).
struct DataExportShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.success)
                Text("Your data is ready")
                    .font(.title3.weight(.semibold))
                Text("A JSON file with your profile, listings, stays, messages, and connections.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .cornerRadius(12)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Color.primaryBackground.ignoresSafeArea())
            .navigationTitle("Export")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Section card modifier

extension View {
    func sectionCard() -> some View {
        self
            .background(Color.secondaryText.opacity(0.07))
            .cornerRadius(14)
            .padding(.horizontal)
    }
}

// MARK: - Settings row

struct SettingsRow: View {
    let icon: String
    let label: String
    var chevron: Bool = false
    var trailingText: String? = nil
    var accessibilityID: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundColor(Color.accent)
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                if let text = trailingText {
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondaryText.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .disabled(action == nil && !chevron)
        .accessibilityIdentifier(accessibilityID ?? "")
    }
}

// MARK: - Edit name sheet

struct EditNameSheet: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @Environment(StayRequestStore.self) private var stayRequestStore
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
                    Section { InlineErrorLabel(message: errorMessage) }
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
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The name on the user document is the authoritative one, and it is now
        // saved. Fanning it out to the two denormalized copies — listing cards
        // (homes.hostName) and trip rows (stayRequests.listingHostName, L7) — is
        // best effort from here.
        //
        // These used to run inside the do above, so a listing that refused the
        // rewrite (one predating the friends-only migration, whose whole document
        // the update rule re-validates) reported the rename as failed even though
        // it had already happened, and took the second fan-out down with it. A
        // stale denormalized copy is a cosmetic problem; telling someone their
        // rename failed when it did not is a worse one. Each runs regardless of
        // the other, and each reports itself rather than the sheet.
        do {
            try await homeStore.updateHostName(for: authManager.userID, newName: trimmed)
        } catch {
            Telemetry.recordError(error, context: "hostName fan-out after rename")
        }
        do {
            try await stayRequestStore.updateHostName(for: authManager.userID, newName: trimmed)
        } catch {
            Telemetry.recordError(error, context: "listingHostName fan-out after rename")
        }
        dismiss()
    }
}

#Preview("Data export") {
    DataExportShareSheet(url: URL(fileURLWithPath: "/tmp/freebnb-export.json"))
}

#Preview("Settings rows") {
    VStack(spacing: 0) {
        SettingsRow(icon: "bell", label: "Notifications", chevron: true)
        SettingsRow(icon: "person", label: "Account", trailingText: "Apple")
    }
    .sectionCard()
}

#Preview("Edit name") {
    EditNameSheet()
        .previewEnvironment()
}

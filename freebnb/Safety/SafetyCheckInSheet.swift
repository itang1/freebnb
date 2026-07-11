//
//  SafetyCheckInSheet.swift
//  freebnb
//
//  "Share my stay" (feature 5): tell one person where you'll be and when.
//
//  The message is composed on-device and handed to the system share sheet, so
//  the address travels through the guest's own Messages or Mail. FreeBNB never
//  sends it anywhere, which means the emergency contact needs no account, and
//  the disclosure surface doesn't grow by a single service.
//

import SwiftUI

struct SafetyCheckInSheet: View {
    let stay: StayRequest
    /// The exact address, when this guest has earned it. Nil before the host
    /// accepts, in which case the shared message says the city and says why.
    let location: ListingLocation?
    let manual: HouseManual?

    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var contactName = ""
    @State private var contactHandle = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var contact: EmergencyContact {
        EmergencyContact(
            name: contactName.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: contactHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var message: String {
        SafetyCheckIn.message(
            stay: stay,
            guestName: userProfileStore.displayName ?? "Your friend",
            location: location,
            manual: manual
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Send one person your dates and address. They'll get it from you directly — FreeBNB doesn't message them.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section {
                    TextField("Name", text: $contactName)
                        .textContentType(.name)
                    TextField("Phone or email", text: $contactHandle)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Emergency contact")
                } footer: {
                    Text("Saved privately to your account so you don't retype it next trip. Only you can see it.")
                }

                Section("What they'll receive") {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                if location == nil {
                    Section {
                        Label(
                            "Your host hasn't accepted this stay yet, so the exact address isn't in the message.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                Section {
                    ShareLink(item: message) {
                        Label("Share my stay", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .simultaneousGesture(TapGesture().onEnded { Task { await saveContact() } })
                }

                if let errorMessage {
                    Section { InlineErrorLabel(message: errorMessage) }
                }
            }
            .navigationTitle("Safety check-in")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                contactName = userProfileStore.currentProfile?.emergencyContact?.name ?? ""
                contactHandle = userProfileStore.currentProfile?.emergencyContact?.contact ?? ""
            }
        }
    }

    /// Remembers the contact for next time. A failure here must not block the
    /// share: getting the message out matters more than remembering who it went to.
    private func saveContact() async {
        guard contact.isComplete, contact != userProfileStore.currentProfile?.emergencyContact else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await userProfileStore.updateEmergencyContact(contact)
        } catch {
            errorMessage = "Couldn't save your contact for next time, but your message is ready to send."
        }
    }
}

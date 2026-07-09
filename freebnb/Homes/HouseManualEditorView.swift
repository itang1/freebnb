//
//  HouseManualEditorView.swift
//  freebnb
//
//  Host-only editor for a listing's house manual (feature 15). Loads the current
//  manual on appear and writes it back through HomeStore, which is gated by the
//  accepted-guest rule so only the host can edit and only accepted guests can read.
//

import SwiftUI

struct HouseManualEditorView: View {
    let homeID: String

    @Environment(HomeStore.self) private var homeStore
    @Environment(\.dismiss) private var dismiss

    @State private var manual = HouseManual()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section { ProgressView() }
                } else {
                    Section {
                        TextField("Check-in instructions", text: $manual.checkInInstructions, axis: .vertical)
                            .lineLimit(2...6)
                    } header: {
                        Text("Getting in")
                    } footer: {
                        Text("Shown to a guest once you accept their stay.")
                    }

                    Section("Wifi") {
                        TextField("Network name", text: $manual.wifiNetwork)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Password", text: $manual.wifiPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Key handoff") {
                        TextField("How keys are exchanged", text: $manual.keyHandoff, axis: .vertical)
                            .lineLimit(1...4)
                    }

                    Section("House notes & quirks") {
                        TextField("Anything else a guest should know", text: $manual.houseNotes, axis: .vertical)
                            .lineLimit(2...8)
                    }

                    Section {
                        TextField("Phone number", text: $manual.hostPhone)
                            .keyboardType(.phonePad)
                    } header: {
                        Text("Arrival-day contact")
                    } footer: {
                        Text("A number an accepted guest can reach you on for check-in. Only shared after you accept.")
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("House Manual")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isLoading || isSaving)
                }
            }
            .task {
                if let existing = await homeStore.manual(for: homeID) { manual = existing }
                isLoading = false
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await homeStore.saveManual(homeID: homeID, manual: manual)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    HouseManualEditorView(homeID: "preview")
        .environment(HomeStore())
}

//
//  HostCancelStaySheet.swift
//  freebnb
//
//  The sheet for a host calling off a stay the guest was given: it says plainly what the guest will be told and
//  offers (never demands) a note to suggest other dates. There's no reason field, so a host with nothing to
//  add just cancels.
//

import SwiftUI

struct HostCancelStaySheet: View {
    let request: StayRequest
    /// The guest's display name, so the sheet names who hears about this.
    let guestName: String
    /// Performs the cancel with the host's optional note; nil on success, else the message to show (the
    /// presenting page is behind the sheet).
    let onConfirm: (_ note: String?) async -> String?

    @State private var note = ""
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(guestName) will hear right away that you had to cancel. The dates open back up on your listing, and they can look at your other dates if they'd like.")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }

                Section("Suggest other dates (optional)") {
                    TextField("If some other dates might work, let them know here...", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let errorMessage {
                    Section { InlineErrorLabel(message: errorMessage) }
                }
            }
            .navigationTitle("Cancel Stay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep stay") { dismiss() }.disabled(isConfirming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel stay", role: .destructive) {
                        isConfirming = true
                        errorMessage = nil
                        Task {
                            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                            errorMessage = await onConfirm(trimmed.isEmpty ? nil : trimmed)
                            isConfirming = false
                            // Owns its dismissal: stays open on failure with the reason, closes on success.
                            if errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(isConfirming)
                }
            }
            .disabled(isConfirming)
        }
    }
}

#Preview {
    HostCancelStaySheet(
        request: StayRequest(
            listingID: "L1",
            listingCity: "Pasadena",
            listingTitle: "Guest room by the Rose Bowl",
            listingHostName: "You",
            hostUserID: "host1",
            guestUserID: "guest1",
            checkIn: Date(),
            checkOut: Date().addingTimeInterval(3 * 86_400),
            status: .accepted
        ),
        guestName: "Maya",
        onConfirm: { _ in nil }
    )
}

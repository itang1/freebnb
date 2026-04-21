//
//  RequestStaySheet.swift
//  freebnb
//

import SwiftUI

struct RequestStaySheet: View {
    let listing: Home

    @Environment(StayRequestStore.self) private var requestStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var checkIn: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
    @State private var checkOut: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400 * 2))
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    private var canSend: Bool {
        !isSending && checkOut > checkIn && nights <= listing.maxStayDays
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dates") {
                    DatePicker("Check in", selection: $checkIn, in: Date()..., displayedComponents: .date)
                    DatePicker("Check out", selection: $checkOut, in: checkIn.addingTimeInterval(86400)..., displayedComponents: .date)

                    if nights > 0 {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(nights) night\(nights == 1 ? "" : "s")")
                                .foregroundColor(nights > listing.maxStayDays ? .red : .secondary)
                        }
                    }
                    if nights > listing.maxStayDays {
                        Label("Max stay is \(listing.maxStayDays) nights", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Note to host (optional)") {
                    TextField("Introduce yourself, share your travel context...", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Request a Stay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(!canSend)
                }
            }
            .disabled(isSending)
        }
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await requestStore.send(
                listing: listing,
                guestUserID: authManager.userID,
                checkIn: checkIn,
                checkOut: checkOut,
                guestNote: note.isEmpty ? nil : note
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

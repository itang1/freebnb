//
//  RequestStaySheet.swift
//  freebnb
//

import SwiftUI

struct RequestStaySheet: View {
    let listing: Home

    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var checkIn: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    )
    @State private var checkOut: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
    )
    @State private var note = ""
    @State private var guestCount = 1
    @State private var arrivalWindow: ArrivalWindow = .flexible
    @State private var isSending = false
    @State private var errorMessage: String?

    private var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    private var blockedConflict: DateRange? {
        listing.blockedDateRanges?.first { $0.overlaps(checkIn: checkIn, checkOut: checkOut) }
    }

    // A stay this guest has already had accepted for this listing that overlaps
    // the requested dates. The rules hide other guests' bookings, so this is the
    // only double-booking a client can honestly detect — but it's the common one
    // (re-requesting dates you're already confirmed for) and it would fail the
    // host's overlap check at accept time anyway (L10).
    private var acceptedConflict: StayRequest? {
        requestStore.outgoingRequests.first { req in
            req.listingID == listing.id
                && req.status == .accepted
                && req.overlaps(checkIn: checkIn, checkOut: checkOut)
        }
    }

    private var canSend: Bool {
        !isSending && checkOut > checkIn && nights <= listing.guestPolicy.maxStayDays
            && blockedConflict == nil && acceptedConflict == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dates") {
                    DatePicker("Check in", selection: $checkIn, in: Date()..., displayedComponents: .date)
                    DatePicker("Check out", selection: $checkOut, in: (Calendar.current.date(byAdding: .day, value: 1, to: checkIn) ?? checkIn)..., displayedComponents: .date)

                    if nights > 0 {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(nights) night\(nights == 1 ? "" : "s")")
                                .foregroundColor(nights > listing.guestPolicy.maxStayDays ? .red : .secondary)
                        }
                    }
                    if nights > listing.guestPolicy.maxStayDays {
                        Label("Max stay is \(listing.guestPolicy.maxStayDays) nights", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if let conflict = blockedConflict {
                        let f = AppDateFormatters.shortDay
                        Label("Host is unavailable \(f.string(from: conflict.start)) – \(f.string(from: conflict.end))", systemImage: "calendar.badge.minus")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if let conflict = acceptedConflict {
                        let f = AppDateFormatters.shortDay
                        Label("You already have an accepted stay here \(f.string(from: conflict.checkIn)) – \(f.string(from: conflict.checkOut))", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Party") {
                    Stepper(value: $guestCount, in: 1...max(1, listing.guestPolicy.maxGuests)) {
                        HStack {
                            Text("Guests")
                            Spacer()
                            Text("\(guestCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("This place hosts up to \(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Arrival") {
                    Picker("Arrival time", selection: $arrivalWindow) {
                        ForEach(ArrivalWindow.allCases, id: \.self) { window in
                            Text(window.displayName).tag(window)
                        }
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
                guestNote: note.isEmpty ? nil : note,
                guestCount: guestCount,
                arrivalWindow: arrivalWindow
            )
            messageStore.sendStayEvent(
                StayEvent(kind: .requested, dateRange: dateRangeText(from: checkIn, to: checkOut, nights: nights)),
                senderUserID: authManager.userID,
                recipientUserID: listing.hostUserID
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dateRangeText(from start: Date, to end: Date, nights: Int) -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: start)) – \(f.string(from: end)) · \(nights) night\(nights == 1 ? "" : "s")"
    }
}

#Preview {
    RequestStaySheet(listing: PreviewData.home)
        .environment(StayRequestStore(repository: InMemoryStayRequestsRepository()))
        .environment(MessageStore(repository: InMemoryMessagesRepository()))
        .environment(AuthManager())
}

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

    // Nil until the guest taps. Nothing is pre-filled because the grid knows which
    // days are gone and a default has no way to: tomorrow may be the middle of a
    // week the host blocked, and opening on an error the guest didn't cause is a
    // poor way to start.
    @State private var checkIn: Date?
    @State private var checkOut: Date?
    @State private var note = ""
    @State private var guestCount = 1
    @State private var arrivalWindow: ArrivalWindow = .flexible
    @State private var isSending = false
    @State private var errorMessage: String?

    private var nights: Int {
        guard let checkIn, let checkOut else { return 0 }
        return max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    // Any date the listing isn't free: the host's blocked ranges and the ranges an
    // accepted stay has taken, together (`unavailableRanges`). The grid already
    // refuses to select across these, so this is the second lock on the same door:
    // the listing can change under an open sheet.
    private var unavailableConflict: DateRange? {
        guard let checkIn, let checkOut else { return nil }
        return listing.unavailableRanges.first { $0.overlaps(checkIn: checkIn, checkOut: checkOut) }
    }

    // The days the grid greys out, computed once per listing rather than per cell.
    private var unavailableDays: Set<Date> {
        AvailabilityCalendar.blockedDays(in: listing.unavailableRanges)
    }

    private var acceptedConflict: StayRequest? {
        guard let checkIn, let checkOut else { return nil }
        return requestStore.outgoingRequests.first { req in
            req.listingID == listing.id
                && req.status == .accepted
                && req.overlaps(checkIn: checkIn, checkOut: checkOut)
        }
    }

    private var canSend: Bool {
        guard let checkIn, let checkOut else { return false }
        return !isSending && checkOut > checkIn && nights <= listing.guestPolicy.maxStayDays
            && unavailableConflict == nil && acceptedConflict == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // Which place this request is for. A host can list more than one
                // home and the thread is shared across all of them, so "Request a
                // Stay" alone wouldn't say which one you're asking about.
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .foregroundColor(.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.displayTitle)
                                .font(.subheadline.weight(.semibold))
                            Text("\(listing.address.city), \(listing.address.state)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Dates") {
                    StayDateGrid(unavailableDays: unavailableDays, checkIn: $checkIn, checkOut: $checkOut)
                        .padding(.vertical, 4)

                    HStack {
                        Text(selectionPrompt)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if checkIn != nil {
                            Button("Clear") {
                                checkIn = nil
                                checkOut = nil
                            }
                            .font(.caption)
                        }
                    }

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
                    // The own-stay message is more specific, so it wins: an overlap
                    // that is the guest's own confirmed stay shows only that, not
                    // the generic "host is unavailable" the same dates would trip.
                    if let conflict = acceptedConflict {
                        let f = AppDateFormatters.shortDay
                        Label("You already have an accepted stay here \(f.string(from: conflict.checkIn)) – \(f.string(from: conflict.checkOut))", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if let conflict = unavailableConflict {
                        let f = AppDateFormatters.shortDay
                        Label("Host is unavailable \(f.string(from: conflict.start)) – \(f.string(from: conflict.end))", systemImage: "calendar.badge.minus")
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
                        .buttonStyle(.borderedProminent)
                        .tint(Color.callToAction)
                        .disabled(!canSend)
                }
            }
            .disabled(isSending)
        }
    }

    /// What the grid is waiting for, so the two taps it takes are never a guess.
    private var selectionPrompt: String {
        let formatter = AppDateFormatters.shortDay
        guard let checkIn else { return "Tap a day to set your check in" }
        guard let checkOut else { return "Check in \(formatter.string(from: checkIn)) · tap a later day to check out" }
        return "\(formatter.string(from: checkIn)) – \(formatter.string(from: checkOut))"
    }

    private func send() async {
        guard let checkIn, let checkOut else { return }
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
        .previewEnvironment()
}

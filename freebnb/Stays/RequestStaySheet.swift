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
    @Environment(BookingPolicyStore.self) private var policyStore
    @Environment(\.dismiss) private var dismiss

    // The host's booking rules for this guest, resolved once when the sheet opens
    // (see BookingPolicyStore). They only subtract options; nothing says a rule exists,
    // since the restricted guest is who must not be told.
    @State private var resolvedPolicy: BookingPolicyStore.Resolved = .unrestricted

    // Nil until the guest taps: the grid knows which days are gone and a default doesn't.
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

    // Any unavailable date (blocked plus accepted-stay ranges). The grid already refuses
    // to select across them; this is the second lock, since the listing can change under an open sheet.
    private var unavailableConflict: DateRange? {
        guard let checkIn, let checkOut else { return nil }
        return listing.unavailableRanges.first { $0.overlaps(checkIn: checkIn, checkOut: checkOut) }
    }

    // The greyed days, computed once per listing. Blocked days, other stays and this
    // guest's withheld days arrive indistinguishable, so a restricted guest has nothing to compare.
    private var unavailableDays: Set<Date> {
        AvailabilityCalendar.blockedDays(in: listing.unavailableRanges)
            .union(BookingPolicyGuestView.daysWithheld(
                by: resolvedPolicy.policy,
                staysUsedInWindow: resolvedPolicy.staysUsedInWindow,
                windowEndsAt: resolvedPolicy.windowEndsAt,
                monthsAhead: StayDateGrid.monthsAhead
            ))
    }

    /// The arrival times this guest may pick; a withheld one is simply absent (no disabled row or "ask your
    /// host").
    private var arrivalChoices: [ArrivalWindow] {
        let allowed = resolvedPolicy.policy.allowedArrivalWindows
        return allowed.isEmpty ? ArrivalWindow.allCases : allowed
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
            // The set can grow under an open sheet (policy resolving, a frequency window
            // closing); re-checking keeps Send from offering a write the rules would refuse.
            && AvailabilityCalendar.isStaySelectable(
                checkIn: checkIn, checkOut: checkOut, unavailableDays: unavailableDays
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                // Which place this request is for; one host may list several homes sharing a thread.
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
                                .foregroundColor(.secondaryText)
                        }
                    }
                }

                Section("Dates") {
                    StayDateGrid(unavailableDays: unavailableDays, checkIn: $checkIn, checkOut: $checkOut)
                        .padding(.vertical, 4)

                    HStack {
                        Text(selectionPrompt)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
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
                                .foregroundColor(nights > listing.guestPolicy.maxStayDays ? .danger : .secondaryText)
                        }
                    }
                    if nights > listing.guestPolicy.maxStayDays {
                        Label("Max stay is \(listing.guestPolicy.maxStayDays) nights", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundColor(.danger)
                    }
                    // The own-stay message wins: an overlap with the guest's own confirmed stay
                    // names itself, while any other conflict (booked, blocked, buffer) gets the
                    // neutral line, naming no span.
                    if let conflict = acceptedConflict {
                        let f = AppDateFormatters.shortDay
                        Label("You already have an accepted stay here \(f.string(from: conflict.checkIn)) – \(f.string(from: conflict.checkOut))", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                            .foregroundColor(.danger)
                    } else if unavailableConflict != nil {
                        Label("Those dates aren't available", systemImage: "calendar.badge.minus")
                            .font(.caption)
                            .foregroundColor(.danger)
                    }
                }

                Section("Party") {
                    Stepper(value: $guestCount, in: 1...max(1, listing.guestPolicy.maxGuests)) {
                        HStack {
                            Text("Guests")
                            Spacer()
                            Text("\(guestCount)")
                                .foregroundColor(.secondaryText)
                        }
                    }
                    Text("This place hosts up to \(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }

                Section("Arrival") {
                    Picker("Arrival time", selection: $arrivalWindow) {
                        ForEach(arrivalChoices, id: \.self) { window in
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
                            .foregroundColor(.danger)
                    }
                }
            }
            .navigationTitle("Request a Stay")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadPolicy() }
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

    /// What the grid is waiting for, so the two taps are never a guess.
    private var selectionPrompt: String {
        let formatter = AppDateFormatters.shortDay
        guard let checkIn else { return "Tap a day to set your check in" }
        guard let checkOut else { return "Check in \(formatter.string(from: checkIn)) · tap a later day to check out" }
        return "\(formatter.string(from: checkIn)) – \(formatter.string(from: checkOut))"
    }

    /// Loads the host's rules for this guest and re-points the arrival picker if its
    /// default was withheld (a missing selection would blank the row and draw attention).
    private func loadPolicy() async {
        resolvedPolicy = await policyStore.resolve(
            hostID: listing.hostUserID,
            guestID: authManager.userID
        )
        if !resolvedPolicy.policy.allows(arrivalWindow), let first = arrivalChoices.first {
            arrivalWindow = first
        }
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
                arrivalWindow: arrivalWindow,
                // Spends a slot against the host's frequency cap in the same commit; nil when there's no cap.
                advancing: policyStore.advancedCounter(
                    for: resolvedPolicy,
                    hostID: listing.hostUserID,
                    guestID: authManager.userID
                )
            )
            messageStore.sendStayEvent(
                StayEvent(kind: .requested, dateRange: dateRangeText(from: checkIn, to: checkOut, nights: nights)),
                senderUserID: authManager.userID,
                recipientUserID: listing.hostUserID
            )
            dismiss()
        } catch {
            errorMessage = StayRequestError.guestFacingMessage(for: error)
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

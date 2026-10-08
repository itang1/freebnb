//
//  StayRows.swift
//  freebnb
//
//  The row, badge and sheet views the Stays tab composes (split from StaysTab.swift).
//

import SwiftUI

// MARK: - Outgoing row (traveler view)

struct OutgoingRequestRow: View {
    let request: StayRequest
    var onCancel: (() -> Void)? = nil
    /// Change dates without cancel-and-resend; only while pending.
    var onModify: (() -> Void)? = nil
    /// Tell someone where you'll be; on any confirmed trip.
    var onShare: (() -> Void)? = nil
    /// Close the stay out; nil until it has begun.
    var onComplete: (() -> Void)? = nil
    /// Answer a host's offer; non-nil only while `.offered`, the one status where the guest owes a reply.
    var onAccept:  (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil

    private var showsOfferActions: Bool {
        request.status == .offered && onAccept != nil && onDecline != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(request.listingHostName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: request.status)
            }

            Text("\(request.listingCity) · \(AppDateFormatters.mediumDate.string(from: request.checkIn)) – \(AppDateFormatters.mediumDate.string(from: request.checkOut))")
                .font(.subheadline)
                .foregroundColor(.secondaryText)

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondaryText)

            if let summary = request.partySummary {
                Label(summary, systemImage: "person.2")
                    .font(.caption).foregroundColor(.secondaryText)
            }

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondaryText).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Host note: \(note)")
                    .font(.caption).foregroundColor(.secondaryText).lineLimit(2)
            }

            if onModify != nil || onShare != nil || onComplete != nil {
                HStack(spacing: 12) {
                    if let onModify {
                        StayActionButton(title: "Change dates", systemImage: "calendar.badge.clock", action: onModify)
                    }
                    if let onShare {
                        StayActionButton(title: "Share my stay", systemImage: "shield.lefthalf.filled", action: onShare)
                    }
                    if let onComplete {
                        StayActionButton(title: "Mark complete", systemImage: "checkmark.circle", action: onComplete)
                    }
                }
                .padding(.top, 4)
            }

            if let onCancel, request.status.isActive {
                Button(role: .destructive, action: onCancel) {
                    // A pending request is withdrawn, a confirmed stay called off; the label says which.
                    Text(request.status == .accepted ? "Cancel stay" : "Cancel request")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondaryText.opacity(0.1))
                        .foregroundColor(.danger)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }

            // Answering an offer: "No thanks", since the friend is declining an invitation.
            if showsOfferActions {
                HStack(spacing: 12) {
                    Button(action: { onDecline?() }) {
                        Text("No thanks")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondaryText.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.pressable)

                    Button(action: { onAccept?() }) {
                        // Coral: accepting is the commit action.
                        Text("Yes please")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.callToAction)
                            .foregroundColor(.onAccent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A secondary, full-width action on a stay row.
struct StayActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.secondaryText.opacity(0.1))
                .foregroundColor(.primary)
                .cornerRadius(8)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Review prompt row

/// A finished stay awaiting the user's review. With `onThank` (the viewer was
/// the guest) the primary action is the thank-you flow, then the review; else "Leave a review".
struct ReviewPromptRow: View {
    let request: StayRequest
    let subjectName: String
    let onReview: () -> Void
    var onThank: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subjectName)
                .font(.headline)
            Text("\(request.listingCity) · \(request.dateRangeText)")
                .font(.subheadline)
                .foregroundColor(.secondaryText)

            Button(action: onThank ?? onReview) {
                Label(onThank == nil ? "Leave a review" : "Say thanks",
                      systemImage: onThank == nil ? "star" : "heart")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accent)
                    .foregroundColor(.onAccent)
                    .cornerRadius(8)
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thank-you sheet

/// An optional gratitude note the guest sends the host after checkout, leading
/// into the review; both paths hand back via `onContinue`.
struct ThankYouSheet: View {
    let hostName: String
    /// `note` is nil when skipped; either way the caller opens the review next.
    let onContinue: (_ note: String?) async -> Void

    @State private var note: String
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    init(hostName: String, onContinue: @escaping (String?) async -> Void) {
        self.hostName = hostName
        self.onContinue = onContinue
        _note = State(initialValue: "Thank you so much for hosting me. I had a wonderful stay!")
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Send \(hostName) a thank-you") {
                    TextField("Say thanks...", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Button {
                        send(trimmedNote.isEmpty ? nil : trimmedNote)
                    } label: {
                        Label("Send thanks & leave a review", systemImage: "heart.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSending || trimmedNote.isEmpty)

                    Button("Skip and just review") { send(nil) }
                        .disabled(isSending)
                }
            }
            .navigationTitle("Thank your host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
            }
            .disabled(isSending)
        }
    }

    private func send(_ note: String?) {
        isSending = true
        Task {
            await onContinue(note)
            isSending = false
        }
    }
}

// MARK: - Incoming row (host view)

struct IncomingRequestRow: View {
    let request: StayRequest
    let guestName: String
    /// Street address, passed when the host has several listings to tell requests apart.
    var listingAddress: String? = nil
    var showActions: Bool = false
    var onAccept:  (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil
    /// Close the stay out; nil until it has begun.
    var onComplete: (() -> Void)? = nil
    /// Call off an accepted stay the host can't honor; the tab confirms first.
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(guestName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: request.status)
            }

            if let listingAddress {
                Text("\(request.listingCity) · \(listingAddress)")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                Text("\(AppDateFormatters.mediumDate.string(from: request.checkIn)) – \(AppDateFormatters.mediumDate.string(from: request.checkOut))")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            } else {
                Text("\(request.listingCity) · \(AppDateFormatters.mediumDate.string(from: request.checkIn)) – \(AppDateFormatters.mediumDate.string(from: request.checkOut))")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondaryText)

            if let summary = request.partySummary {
                Label(summary, systemImage: "person.2")
                    .font(.caption).foregroundColor(.secondaryText)
            }

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondaryText).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Your note: \(note)")
                    .font(.caption).foregroundColor(.secondaryText).lineLimit(2)
            }

            if let onComplete, !showActions {
                StayActionButton(title: "Mark complete", systemImage: "checkmark.circle", action: onComplete)
                    .padding(.top, 4)
            }

            if let onCancel, request.status == .accepted {
                Button(role: .destructive, action: onCancel) {
                    Text("Cancel stay")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondaryText.opacity(0.1))
                        .foregroundColor(.danger)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }

            if showActions {
                HStack(spacing: 12) {
                    Button(action: { onDecline?() }) {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondaryText.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.pressable)

                    Button(action: { onAccept?() }) {
                        Text("Accept")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.callToAction)
                            .foregroundColor(.onAccent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: StayRequestStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .pending:   return .warning
        // Same amber as pending: the badge says the stay is unresolved, not which way it points.
        case .offered:   return .warning
        case .accepted:  return .success
        case .completed: return Color.accent
        case .declined:  return .secondaryText
        case .cancelled: return .secondaryText
        }
    }
}

// MARK: - Accept sheet

struct AcceptSheet: View {
    let request: StayRequest
    /// Performs the accept; nil on success, else the message to show. It comes back
    /// here because the presenting page sits behind the sheet and an error there is invisible.
    let onConfirm: (String?) async -> String?

    @State private var note = ""
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Add a note (optional)") {
                    TextField("Anything the guest should know...", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let errorMessage {
                    Section { InlineErrorLabel(message: errorMessage) }
                }
            }
            .navigationTitle("Accept Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isConfirming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        isConfirming = true
                        errorMessage = nil
                        Task {
                            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                            errorMessage = await onConfirm(trimmed.isEmpty ? nil : trimmed)
                            isConfirming = false
                            // The sheet owns dismissal: stay open on failure, close on success.
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

// MARK: - Modify sheet

struct ModifyStaySheet: View {
    let request: StayRequest
    /// The listing when cached, so the same max-stay and blocked-date guards apply; nil still allows a date
    /// change.
    let listing: Home?
    let onSave: (_ checkIn: Date, _ checkOut: Date) async -> Void

    @State private var checkIn: Date
    @State private var checkOut: Date
    @State private var isSaving = false
    @Environment(BookingPolicyStore.self) private var policyStore
    @Environment(\.dismiss) private var dismiss

    /// The host's rules for this guest. Only the notice window applies: a date
    /// change spends no frequency slot and can't touch the arrival time.
    @State private var resolvedPolicy: BookingPolicyStore.Resolved = .unrestricted

    init(request: StayRequest, listing: Home?, onSave: @escaping (Date, Date) async -> Void) {
        self.request = request
        self.listing = listing
        self.onSave = onSave
        _checkIn = State(initialValue: request.checkIn)
        _checkOut = State(initialValue: request.checkOut)
    }

    private var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    private var maxStay: Int? { listing?.guestPolicy.maxStayDays }

    /// Whether the dates cross a day this listing can't take. Reads the merged
    /// `unavailableRanges`, never blocks alone, or the sheet would reveal which
    /// nights are booked. A Bool, since naming the span leaks the same thing.
    private var hasUnavailableConflict: Bool {
        listing?.unavailableRanges.contains { $0.overlaps(checkIn: checkIn, checkOut: checkOut) } ?? false
    }

    private var hasChanges: Bool {
        checkIn != request.checkIn || checkOut != request.checkOut
    }

    /// The earliest day the picker allows: today or the host's notice window. A
    /// lower bound rather than a warning, matching the rules' bound so the guest
    /// never hits a permissions error.
    private var earliestSelectable: Date {
        max(Date(), resolvedPolicy.policy.earliestCheckIn())
    }

    private var canSave: Bool {
        !isSaving && hasChanges && checkOut > checkIn
            && (maxStay == nil || nights <= maxStay!)
            && !hasUnavailableConflict
            // Dates predating the policy start below the bound; Save stays disabled until a valid date is picked.
            && checkIn >= Calendar.current.startOfDay(for: earliestSelectable)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New dates") {
                    DatePicker("Check in", selection: $checkIn, in: earliestSelectable..., displayedComponents: .date)
                    DatePicker("Check out", selection: $checkOut, in: (Calendar.current.date(byAdding: .day, value: 1, to: checkIn) ?? checkIn)..., displayedComponents: .date)

                    if nights > 0 {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(nights) night\(nights == 1 ? "" : "s")")
                                .foregroundColor(maxStay.map { nights > $0 } == true ? .danger : .secondaryText)
                        }
                    }
                    if let maxStay, nights > maxStay {
                        Label("Max stay is \(maxStay) nights", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundColor(.danger)
                    }
                    if hasUnavailableConflict {
                        Label("Those dates aren't available", systemImage: "calendar.badge.minus")
                            .font(.caption).foregroundColor(.danger)
                    }
                }

                Section {
                    Text("Your host will see the updated dates in your chat. The request stays pending until they respond.")
                        .font(.caption).foregroundColor(.secondaryText)
                }
            }
            .navigationTitle("Change Dates")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                resolvedPolicy = await policyStore.resolve(
                    hostID: request.hostUserID,
                    guestID: request.guestUserID
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(checkIn, checkOut)
                            isSaving = false
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .disabled(isSaving)
        }
    }
}

#Preview("Trip rows") {
    List {
        OutgoingRequestRow(request: PreviewData.pendingStay, onCancel: {}, onModify: {})
        OutgoingRequestRow(request: PreviewData.stay, onShare: {})
        IncomingRequestRow(
            request: PreviewData.pendingStay,
            guestName: "Sam",
            showActions: true,
            onAccept: {},
            onDecline: {}
        )
        ReviewPromptRow(request: PreviewData.stay, subjectName: "Maya", onReview: {}, onThank: {})
        HStack {
            StatusBadge(status: .pending)
            StatusBadge(status: .accepted)
            StatusBadge(status: .declined)
        }
    }
    .listStyle(.plain)
}

#Preview("Accept sheet") {
    AcceptSheet(request: PreviewData.pendingStay) { _ in nil }
}

#Preview("Modify sheet") {
    ModifyStaySheet(request: PreviewData.pendingStay, listing: PreviewData.home) { _, _ in }
}

#Preview("Thank-you sheet") {
    ThankYouSheet(hostName: "Maya") { _ in }
}

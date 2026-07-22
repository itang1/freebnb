//
//  StayRows.swift
//  freebnb
//
//  The row, badge, and sheet views the Stays tab composes. Split out of
//  StaysTab.swift, which is the screen; these are the pieces it arranges.
//

import SwiftUI

// MARK: - Outgoing row (traveler view)

struct OutgoingRequestRow: View {
    let request: StayRequest
    var onCancel: (() -> Void)? = nil
    /// Change dates without cancel-and-resend (feature 23). Offered only while
    /// the request is still pending.
    var onModify: (() -> Void)? = nil
    /// Tell someone where you'll be (feature 5). Offered on any confirmed trip.
    var onShare: (() -> Void)? = nil
    /// Close the stay out (feature 4). Nil until the stay has begun.
    var onComplete: (() -> Void)? = nil
    /// Answer a host's offer (feature 43). Non-nil only while `.offered`, which is
    /// the one status where the guest is the party who owes a reply — every other
    /// row in this list is the guest waiting on somebody else.
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
                    // A pending request is withdrawn; a confirmed stay is called
                    // off. Same verb underneath, but the label should say which.
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

            // Answering a host's offer. "No thanks" rather than "Decline": the
            // friend is turning down an invitation, not rejecting an application,
            // and the button should sound like the former.
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
                        // Coral: accepting is the commit action the row is
                        // asking for, so it takes the call-to-action color.
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

/// A finished stay waiting on the signed-in user's review (features 1 and 4).
/// When `onThank` is set (the viewer was the guest) the primary action is the
/// thank-you flow (feature 24), which sends a gratitude note and then leads into
/// the same review; otherwise it's a plain "Leave a review".
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

// MARK: - Thank-you sheet (guest gratitude after checkout, feature 24)

/// A lightweight gratitude note the guest sends the host after checkout, which
/// then leads straight into leaving a review. The note is optional — a guest who
/// only wants to review can skip it — so both paths hand back to the same review
/// prompt via `onContinue`.
struct ThankYouSheet: View {
    let hostName: String
    /// `note` is nil when the guest skipped sending. Either way the caller then
    /// opens the review, so the thank-you doubles as the review prompt.
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
    /// Street address of the listing. Pass when the host has multiple listings so
    /// the guest can see which property the request is for.
    var listingAddress: String? = nil
    var showActions: Bool = false
    var onAccept:  (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil
    /// Close the stay out (feature 4). Nil until the stay has begun.
    var onComplete: (() -> Void)? = nil
    /// Call off an accepted stay the host can no longer honor. Offered on
    /// upcoming hosting rows; the tab confirms before acting.
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
        // Same amber as pending: both mean "somebody owes an answer", and the
        // badge's job is to say the stay is unresolved, not which way it points.
        case .offered:   return .warning
        case .accepted:  return .success
        case .completed: return Color.accent
        case .declined:  return .secondaryText
        case .cancelled: return .secondaryText
        }
    }
}

// MARK: - Accept sheet (lets host add an optional note)

struct AcceptSheet: View {
    let request: StayRequest
    /// Performs the accept. Returns nil on success, or the message to show the
    /// host on failure. The message has to come back here rather than onto the
    /// presenting page: that page sits behind this sheet, so an error raised
    /// there is invisible and the Accept button looks inert.
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
                            // The sheet owns its own dismissal now, so every
                            // caller gets the same behaviour: stay open on
                            // failure with the reason showing, close on success.
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

// MARK: - Modify sheet (guest changes dates on a pending request, feature 23)

struct ModifyStaySheet: View {
    let request: StayRequest
    /// The listing, when it's cached, so the same max-stay and blocked-date
    /// guards the request sheet enforces apply here too. Nil-safe: an uncached
    /// listing still allows a date change, just without the policy checks.
    let listing: Home?
    let onSave: (_ checkIn: Date, _ checkOut: Date) async -> Void

    @State private var checkIn: Date
    @State private var checkOut: Date
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

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

    /// Whether the proposed dates cross a day this listing can't take. Reads the
    /// merged `unavailableRanges`, never `blockedDateRanges` alone: this sheet is
    /// guest-facing, and validating against the host's blocks by themselves made it
    /// an oracle — dates over a block were refused by name while dates over a
    /// booking sailed through, which told the guest exactly which nights the home
    /// was occupied. A Bool rather than the range, because naming the span is the
    /// other half of the same leak.
    private var hasUnavailableConflict: Bool {
        listing?.unavailableRanges.contains { $0.overlaps(checkIn: checkIn, checkOut: checkOut) } ?? false
    }

    private var hasChanges: Bool {
        checkIn != request.checkIn || checkOut != request.checkOut
    }

    private var canSave: Bool {
        !isSaving && hasChanges && checkOut > checkIn
            && (maxStay == nil || nights <= maxStay!)
            && !hasUnavailableConflict
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New dates") {
                    DatePicker("Check in", selection: $checkIn, in: Date()..., displayedComponents: .date)
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

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
    /// Tell someone where you'll be (feature 5). Offered on any confirmed trip.
    var onShare: (() -> Void)? = nil
    /// Close the stay out (feature 4). Nil until the stay has begun.
    var onComplete: (() -> Void)? = nil

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
                .foregroundColor(.secondary)

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let summary = request.partySummary {
                Label(summary, systemImage: "person.2")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondary).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Host note: \(note)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }

            if onShare != nil || onComplete != nil {
                HStack(spacing: 12) {
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
                    Text("Cancel request")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
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
                .background(Color.secondary.opacity(0.1))
                .foregroundColor(.primary)
                .cornerRadius(8)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Review prompt row

/// A finished stay waiting on the signed-in user's review (features 1 and 4).
struct ReviewPromptRow: View {
    let request: StayRequest
    let subjectName: String
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subjectName)
                .font(.headline)
            Text("\(request.listingCity) · \(request.dateRangeText)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: onReview) {
                Label("Leave a review", systemImage: "star")
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
                    .foregroundColor(.secondary)
                Text("\(AppDateFormatters.mediumDate.string(from: request.checkIn)) – \(AppDateFormatters.mediumDate.string(from: request.checkOut))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("\(request.listingCity) · \(AppDateFormatters.mediumDate.string(from: request.checkIn)) – \(AppDateFormatters.mediumDate.string(from: request.checkOut))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let summary = request.partySummary {
                Label(summary, systemImage: "person.2")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondary).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Your note: \(note)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }

            if let onComplete, !showActions {
                StayActionButton(title: "Mark complete", systemImage: "checkmark.circle", action: onComplete)
                    .padding(.top, 4)
            }

            if showActions {
                HStack(spacing: 12) {
                    Button(action: { onDecline?() }) {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.pressable)

                    Button(action: { onAccept?() }) {
                        Text("Accept")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accent)
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
        case .pending:   return .orange
        case .accepted:  return .green
        case .completed: return Color.accent
        case .declined:  return .secondary
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Accept sheet (lets host add an optional note)

struct AcceptSheet: View {
    let request: StayRequest
    let onConfirm: (String?) async -> Void

    @State private var note = ""
    @State private var isConfirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Add a note (optional)") {
                    TextField("Anything the guest should know...", text: $note, axis: .vertical)
                        .lineLimit(2...6)
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
                        Task {
                            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                            await onConfirm(trimmed.isEmpty ? nil : trimmed)
                            isConfirming = false
                        }
                    }
                    .disabled(isConfirming)
                }
            }
            .disabled(isConfirming)
        }
    }
}

//
//  StaysTab.swift
//  freebnb
//

import SwiftUI

// Root of the Stays tab. Shows the signed-in user's outgoing stay requests
// (as a traveler) and incoming requests (as a host) in one unified view.
struct StaysTab: View {
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @State private var respondingTo: StayRequest?
    @State private var actionError: String?

    // Outgoing (guest / traveler)
    private var pendingOut:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .pending  } }
    private var acceptedOut: [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .accepted } }
    private var pastOut:     [StayRequest] { requestStore.outgoingRequests.filter { !$0.status.isActive   } }

    // Incoming (host)
    private var pendingIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending  } }
    private var acceptedIn: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }
    private var pastIn:     [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive   } }

    private var hasAny: Bool {
        !requestStore.outgoingRequests.isEmpty || !requestStore.incomingRequests.isEmpty
    }

    var body: some View {
        Group {
            if !hasAny {
                ContentUnavailableView {
                    Label("No stays yet", systemImage: "suitcase")
                        .foregroundStyle(Color.appTeal)
                } description: {
                    Text("Request to stay with a host from any listing, and your trips will appear here.")
                }
                .background(Color.creamWhite.ignoresSafeArea())
            } else {
                List {
                    if let actionError {
                        Section {
                            Label(actionError, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }

                    // MARK: Outgoing (your trips)
                    if !pendingOut.isEmpty {
                        Section("Your requests — pending (\(pendingOut.count))") {
                            ForEach(pendingOut) { req in
                                OutgoingRequestRow(request: req) {
                                    Task { await cancel(req) }
                                }
                            }
                        }
                    }
                    if !acceptedOut.isEmpty {
                        Section("Your requests — accepted") {
                            ForEach(acceptedOut) { req in OutgoingRequestRow(request: req) }
                        }
                    }
                    if !pastOut.isEmpty {
                        Section("Your requests — past") {
                            ForEach(pastOut) { req in OutgoingRequestRow(request: req) }
                        }
                    }

                    // MARK: Incoming (your hosting)
                    if !pendingIn.isEmpty {
                        Section("Incoming — pending (\(pendingIn.count))") {
                            ForEach(pendingIn) { req in
                                IncomingRequestRow(
                                    request: req,
                                    guestName: guestName(for: req),
                                    showActions: true,
                                    onAccept:  { respondingTo = req },
                                    onDecline: { Task { await decline(req) } }
                                )
                            }
                        }
                    }
                    if !acceptedIn.isEmpty {
                        Section("Incoming — accepted") {
                            ForEach(acceptedIn) { req in
                                IncomingRequestRow(request: req, guestName: guestName(for: req))
                            }
                        }
                    }
                    if !pastIn.isEmpty {
                        Section("Incoming — past") {
                            ForEach(pastIn) { req in
                                IncomingRequestRow(request: req, guestName: guestName(for: req))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.creamWhite.ignoresSafeArea())
            }
        }
        .navigationTitle("Stays")
        .background(Color.creamWhite.ignoresSafeArea())
        .sheet(item: $respondingTo) { req in
            AcceptSheet(request: req) { hostNote in
                await accept(req, hostNote: hostNote)
            }
        }
    }

    // MARK: - Actions

    private func cancel(_ request: StayRequest) async {
        actionError = nil
        do { try await requestStore.cancel(request) }
        catch { actionError = error.localizedDescription }
    }

    private func accept(_ request: StayRequest, hostNote: String?) async {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            respondingTo = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func decline(_ request: StayRequest) async {
        actionError = nil
        do { try await requestStore.decline(request) }
        catch { actionError = error.localizedDescription }
    }

    private func guestName(for request: StayRequest) -> String {
        userProfileStore.displayName(for: request.guestUserID) ?? "FreeBNB User"
    }
}

// MARK: - Outgoing row (traveler view)

struct OutgoingRequestRow: View {
    let request: StayRequest
    var onCancel: (() -> Void)? = nil

    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(request.listingHostName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: request.status)
            }

            Text("\(request.listingCity) · \(fmt.string(from: request.checkIn)) – \(fmt.string(from: request.checkOut))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondary).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Host note: \(note)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
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
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Incoming row (host view)

struct IncomingRequestRow: View {
    let request: StayRequest
    let guestName: String
    var showActions: Bool = false
    var onAccept:  (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil

    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(guestName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: request.status)
            }

            Text("\(request.listingCity) · \(fmt.string(from: request.checkIn)) – \(fmt.string(from: request.checkOut))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption).foregroundColor(.secondary).italic().lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Your note: \(note)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
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
                    .buttonStyle(.plain)

                    Button(action: { onAccept?() }) {
                        Text("Accept")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.appTeal)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
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
        case .declined:  return .secondary
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Accept sheet (lets host add an optional note)

private struct AcceptSheet: View {
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

//
//  StaysTab.swift
//  freebnb
//

import SwiftUI

// Root of the Stays tab. Shows the signed-in user's outgoing stay requests
// (as a traveler) and incoming requests (as a host) in one unified view.
struct StaysTab: View {
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @State private var respondingTo: StayRequest?
    @State private var actionError: String?

    @State private var showPast = false

    // Outgoing (guest / traveler)
    private var pendingOut:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .pending  } }
    private var acceptedOut: [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .accepted } }
    private var pastOut:     [StayRequest] { requestStore.outgoingRequests.filter { !$0.status.isActive   } }

    // Incoming (host)
    private var pendingIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending  } }
    private var acceptedIn: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }
    private var pastIn:     [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive   } }

    private var hasActive: Bool {
        !pendingOut.isEmpty || !acceptedOut.isEmpty || !pendingIn.isEmpty || !acceptedIn.isEmpty
    }
    private var hasPast: Bool { !pastOut.isEmpty || !pastIn.isEmpty }
    private var hasAny: Bool { hasActive || hasPast }

    var body: some View {
        Group {
            if let error = requestStore.listenerError {
                ContentUnavailableView {
                    Label("Couldn't load stays", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } description: {
                    Text(error)
                        .font(.caption)
                    Button("Retry") { requestStore.reload() }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color.appTeal)
                        .padding(.top, 8)
                }
                .background(Color.creamWhite.ignoresSafeArea())
            } else if !hasAny {
                ContentUnavailableView {
                    Label("No stays yet", systemImage: "suitcase")
                        .foregroundStyle(Color.appTeal)
                } description: {
                    Text("Open a listing, message the host, and request to stay. Your trips appear here.")
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

                    // MARK: Active outgoing (your trips)
                    if !pendingOut.isEmpty {
                        Section("Waiting to hear back") {
                            ForEach(pendingOut, id: \.id) { req in
                                outgoingRow(req, onCancel: { Task { await cancel(req) } })
                            }
                        }
                    }
                    if !acceptedOut.isEmpty {
                        Section("Confirmed trips") {
                            ForEach(acceptedOut, id: \.id) { req in outgoingRow(req) }
                        }
                    }

                    // MARK: Active incoming (your hosting)
                    if !pendingIn.isEmpty {
                        Section("Needs your response") {
                            ForEach(pendingIn, id: \.id) { req in
                                incomingRow(
                                    req,
                                    showActions: true,
                                    onAccept:  { respondingTo = req },
                                    onDecline: { Task { await decline(req) } }
                                )
                            }
                        }
                    }
                    if !acceptedIn.isEmpty {
                        Section("Upcoming hosting") {
                            ForEach(acceptedIn, id: \.id) { req in incomingRow(req) }
                        }
                    }

                    // MARK: Past (collapsed by default)
                    if hasPast {
                        Section {
                            Button {
                                withAnimation { showPast.toggle() }
                            } label: {
                                Label(showPast ? "Hide past stays" : "Show past stays",
                                      systemImage: showPast ? "chevron.up" : "chevron.down")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if showPast {
                            if !pastOut.isEmpty {
                                Section("Past trips") {
                                    ForEach(pastOut, id: \.id) { req in outgoingRow(req) }
                                }
                            }
                            if !pastIn.isEmpty {
                                Section("Past hosting") {
                                    ForEach(pastIn, id: \.id) { req in incomingRow(req) }
                                }
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
        do {
            try await requestStore.cancel(request)
            messageStore.send(
                text: "Request cancelled · \(dateRangeText(request))",
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func accept(_ request: StayRequest, hostNote: String?) async {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            var text = "✅ Stay accepted · \(dateRangeText(request))"
            if let note = hostNote, !note.isEmpty { text += "\n\(note)" }
            messageStore.send(
                text: text,
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
            respondingTo = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func decline(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.decline(request)
            messageStore.send(
                text: "Stay request declined · \(dateRangeText(request))",
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func guestName(for request: StayRequest) -> String {
        userProfileStore.displayName(for: request.guestUserID) ?? "FreeBNB User"
    }

    // MARK: - Row builders

    /// Wraps an OutgoingRequestRow in a NavigationLink if the listing is cached.
    @ViewBuilder
    private func outgoingRow(_ request: StayRequest, onCancel: (() -> Void)? = nil) -> some View {
        if let home = listing(for: request) {
            NavigationLink { HomeDetailPage(home: home) } label: {
                OutgoingRequestRow(request: request, onCancel: onCancel)
            }
        } else {
            OutgoingRequestRow(request: request, onCancel: onCancel)
        }
    }

    /// Wraps an IncomingRequestRow in a NavigationLink if the listing is cached.
    /// Rows with inline Accept/Decline actions are never wrapped — full-width
    /// buttons would cover the entire tap area and prevent navigation.
    @ViewBuilder
    private func incomingRow(
        _ request: StayRequest,
        showActions: Bool = false,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil
    ) -> some View {
        let row = IncomingRequestRow(
            request: request,
            guestName: guestName(for: request),
            showActions: showActions,
            onAccept: onAccept,
            onDecline: onDecline
        )
        if !showActions, let home = listing(for: request) {
            NavigationLink { HomeDetailPage(home: home) } label: { row }
        } else {
            row
        }
    }

    // MARK: - Helpers

    /// Looks up the full Home object for a request from the cached listings.
    private func listing(for request: StayRequest) -> Home? {
        homeStore.listings.first { $0.id == request.listingID }
    }

    private func dateRangeText(_ request: StayRequest) -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))"
    }
}

// MARK: - Outgoing row (traveler view)

struct OutgoingRequestRow: View {
    let request: StayRequest
    var onCancel: (() -> Void)? = nil

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(guestName)
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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

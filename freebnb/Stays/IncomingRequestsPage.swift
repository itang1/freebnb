//
//  IncomingRequestsPage.swift
//  freebnb
//

import SwiftUI

struct IncomingRequestsPage: View {
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @State private var respondingTo: StayRequest? = nil
    @State private var errorMessage: String?

    private var pending: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending } }
    private var past: [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive } }
    private var accepted: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }

    var body: some View {
        Group {
            if requestStore.incomingRequests.isEmpty {
                ContentUnavailableView {
                    Label("No requests yet", systemImage: "calendar.badge.clock")
                        .foregroundStyle(Color.appTeal)
                } description: {
                    Text("When guests request to stay at one of your listings, they'll show up here.")
                }
                .background(Color.creamWhite.ignoresSafeArea())
            } else {
                List {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }

                    if !pending.isEmpty {
                        Section("Pending (\(pending.count))") {
                            ForEach(pending) { request in
                                RequestRow(
                                    request: request,
                                    guestName: guestName(for: request),
                                    showActions: true,
                                    onAccept: { respondingTo = request },
                                    onDecline: { Task { await decline(request) } }
                                )
                            }
                        }
                    }

                    if !accepted.isEmpty {
                        Section("Accepted") {
                            ForEach(accepted) { request in
                                RequestRow(request: request, guestName: guestName(for: request))
                            }
                        }
                    }

                    if !past.isEmpty {
                        Section("Past") {
                            ForEach(past) { request in
                                RequestRow(request: request, guestName: guestName(for: request))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.creamWhite.ignoresSafeArea())
            }
        }
        .navigationTitle("Incoming Requests")
        .sheet(item: $respondingTo) { request in
            AcceptSheet(request: request) { hostNote in
                await accept(request, hostNote: hostNote)
            }
        }
    }

    private func guestName(for request: StayRequest) -> String {
        userProfileStore.displayName(for: request.guestUserID) ?? "FreeBNB User"
    }

    private func accept(_ request: StayRequest, hostNote: String?) async {
        errorMessage = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            respondingTo = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decline(_ request: StayRequest) async {
        errorMessage = nil
        do {
            try await requestStore.decline(request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Request row

private struct RequestRow: View {
    let request: StayRequest
    let guestName: String
    var showActions: Bool = false
    var onAccept: (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(guestName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: request.status)
            }

            Text("\(request.listingCity) · \(dateFormatter.string(from: request.checkIn)) – \(dateFormatter.string(from: request.checkOut))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(request.nights) night\(request.nights == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let note = request.guestNote, !note.isEmpty {
                Text("\"\(note)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .lineLimit(2)
            }

            if let note = request.hostNote, !note.isEmpty {
                Text("Your note: \(note)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
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

private struct StatusBadge: View {
    let status: StayRequestStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:   return .orange
        case .accepted:  return .green
        case .declined:  return .secondary
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Accept sheet

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
                    TextField("Anything the guest should know about their stay...", text: $note, axis: .vertical)
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
                            await onConfirm(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note)
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

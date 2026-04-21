//
//  YourStaysPage.swift
//  freebnb
//

import SwiftUI

struct YourStaysPage: View {
    @Environment(StayRequestStore.self) private var requestStore
    @State private var cancelError: String?

    private var pending:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .pending  } }
    private var accepted: [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .accepted } }
    private var past:     [StayRequest] { requestStore.outgoingRequests.filter { !$0.status.isActive   } }

    var body: some View {
        Group {
            if requestStore.outgoingRequests.isEmpty {
                ContentUnavailableView {
                    Label("No stays yet", systemImage: "suitcase")
                        .foregroundStyle(Color.appTeal)
                } description: {
                    Text("When you request to stay with a host, it'll appear here.")
                }
                .background(Color.creamWhite.ignoresSafeArea())
            } else {
                List {
                    if let cancelError {
                        Section {
                            Label(cancelError, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }

                    if !pending.isEmpty {
                        Section("Pending (\(pending.count))") {
                            ForEach(pending) { request in
                                OutgoingRequestRow(request: request) {
                                    Task { await cancel(request) }
                                }
                            }
                        }
                    }

                    if !accepted.isEmpty {
                        Section("Accepted") {
                            ForEach(accepted) { request in
                                OutgoingRequestRow(request: request)
                            }
                        }
                    }

                    if !past.isEmpty {
                        Section("Past") {
                            ForEach(past) { request in
                                OutgoingRequestRow(request: request)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.creamWhite.ignoresSafeArea())
            }
        }
        .navigationTitle("Your Stays")
    }

    private func cancel(_ request: StayRequest) async {
        cancelError = nil
        do {
            try await requestStore.cancel(request)
        } catch {
            cancelError = error.localizedDescription
        }
    }
}

// MARK: - Outgoing request row

private struct OutgoingRequestRow: View {
    let request: StayRequest
    var onCancel: (() -> Void)? = nil

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(request.listingHostName)
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
                Text("Host note: \(note)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
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

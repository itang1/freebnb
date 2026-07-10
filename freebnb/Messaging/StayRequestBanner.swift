//
//  StayRequestBanner.swift
//  freebnb
//
//  The accept/decline/cancel strip pinned above a chat thread that has an
//  active stay request. Split out of MessagingPage.swift (A2).
//

import SwiftUI

struct StayRequestBanner: View {
    let request: StayRequest
    /// Drives which side of the request the viewer can act on.
    let iAmGuest: Bool
    /// True while an action is in flight; disables every button.
    let isBusy: Bool
    let onCancel: () -> Void
    let onDecline: () -> Void
    let onAccept: () -> Void

    private var tint: Color { request.status == .accepted ? .green : .orange }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusBadge(status: request.status)
                    Text(request.dateRangeText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let note = request.guestNote, !note.isEmpty {
                    Text("\"\(note)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
    }

    @ViewBuilder
    private var actions: some View {
        if iAmGuest, request.status.isActive {
            Button("Cancel", action: onCancel)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(isBusy)
        } else if !iAmGuest, request.status == .pending {
            HStack(spacing: 8) {
                Button("Decline", action: onDecline)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .disabled(isBusy)
                Button("Accept", action: onAccept)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accent)
                    .clipShape(Capsule())
                    .disabled(isBusy)
            }
        }
    }
}

private extension StayRequest {
    static var previewPending: StayRequest {
        StayRequest(
            listingID: "preview-listing",
            listingCity: "Pasadena",
            listingHostName: "Shai",
            hostUserID: "preview-host",
            guestUserID: "preview-guest",
            checkIn: Date(),
            checkOut: Date().addingTimeInterval(3 * 86_400),
            guestNote: "Coming in for a wedding, happy to bring coffee."
        )
    }
}

#Preview {
    VStack(spacing: 0) {
        // Host's view: decline / accept.
        StayRequestBanner(request: .previewPending, iAmGuest: false, isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
        // Guest's view: cancel only.
        StayRequestBanner(request: .previewPending, iAmGuest: true, isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
    }
}

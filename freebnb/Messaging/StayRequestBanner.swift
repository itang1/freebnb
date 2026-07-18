//
//  StayRequestBanner.swift
//  freebnb
//
//  The accept/decline/cancel strip pinned above a chat thread for one active
//  stay request. A thread stacks one of these per active request, so a request
//  in each direction shows as two strips. Split out of MessagingPage.swift (A2).
//

import SwiftUI

struct StayRequestBanner: View {
    let request: StayRequest
    /// The signed-in user, so the banner can say which side of the stay they're
    /// on and offer the actions that side actually has.
    let viewerID: String
    /// The other participant's display name, used in the headline.
    let otherName: String
    /// True while an action is in flight; disables every button.
    let isBusy: Bool
    /// Cancel for a request the viewer sent, withdraw for an offer they made,
    /// or call off an accepted stay. The parent maps the label to the right write.
    let onCancel: () -> Void
    let onDecline: () -> Void
    let onAccept: () -> Void

    private var viewerIsHost: Bool { request.role(of: viewerID) == .host }
    private var tint: Color { request.status == .accepted ? .green : .orange }

    /// Says which way the stay points, because status, dates, and a home name
    /// alone read identically from both sides.
    private var headline: String {
        switch request.status {
        case .offered:
            return viewerIsHost
                ? "Your offer to host \(otherName)"
                : "\(otherName) offered you a place to stay"
        case .accepted:
            return viewerIsHost
                ? "\(otherName)'s stay at your place"
                : "Your stay at \(otherName)'s place"
        default:
            return viewerIsHost
                ? "\(otherName) asked to stay at your place"
                : "Your request to stay at \(otherName)'s place"
        }
    }

    /// The note the person who started the stay attached to it.
    private var initiatorNote: String? {
        request.initiator == .host ? request.hostNote : request.guestNote
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    StatusBadge(status: request.status)
                    Text(request.dateRangeText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                // Names the home this request is for. The thread is shared across
                // all of a host's listings, so this (title if set, else city) is
                // what tells two of them apart here.
                Label(request.listingLabel, systemImage: "house.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .labelStyle(.titleAndIcon)
                if let note = initiatorNote, !note.isEmpty {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(headline). \(request.status.displayName). \(request.dateRangeText)")
    }

    @ViewBuilder
    private var actions: some View {
        switch request.status {
        case .pending:
            if viewerIsHost {
                answerButtons(declineTitle: "Decline", acceptTitle: "Accept")
            } else {
                cancelButton(title: "Cancel")
            }
        case .offered:
            if viewerIsHost {
                cancelButton(title: "Withdraw")
            } else {
                // The guest answering an offer, worded like the Stays tab: an
                // invitation is turned down, not rejected.
                answerButtons(declineTitle: "No thanks", acceptTitle: "Yes please")
            }
        case .accepted:
            // Either party may call off a confirmed stay, same as the Stays tab.
            cancelButton(title: "Cancel")
        case .completed, .declined, .cancelled:
            EmptyView()
        }
    }

    private func cancelButton(title: String) -> some View {
        Button(title, action: onCancel)
            .font(.caption)
            .foregroundColor(.red)
            .disabled(isBusy)
    }

    private func answerButtons(declineTitle: String, acceptTitle: String) -> some View {
        HStack(spacing: 8) {
            Button(declineTitle, action: onDecline)
                .font(.caption)
                .foregroundColor(.secondary)
                .disabled(isBusy)
            Button(acceptTitle, action: onAccept)
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

private extension StayRequest {
    static func preview(status: StayRequestStatus, hostInitiated: Bool = false) -> StayRequest {
        StayRequest(
            listingID: "preview-listing",
            listingCity: "Pasadena",
            listingHostName: "Shai",
            hostUserID: "preview-host",
            guestUserID: "preview-guest",
            checkIn: Date(),
            checkOut: Date().addingTimeInterval(3 * 86_400),
            guestNote: hostInitiated ? nil : "Coming in for a wedding, happy to bring coffee.",
            hostNote: hostInitiated ? "The guest room is free that week if you want it." : nil,
            status: status,
            initiatedBy: hostInitiated ? "preview-host" : nil
        )
    }
}

#Preview {
    VStack(spacing: 0) {
        // Host's view of a guest's request: decline / accept.
        StayRequestBanner(request: .preview(status: .pending), viewerID: "preview-host",
                          otherName: "Maya", isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
        // Guest's view of their own request: cancel only.
        StayRequestBanner(request: .preview(status: .pending), viewerID: "preview-guest",
                          otherName: "Shai", isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
        // Guest's view of a host's offer: no thanks / yes please.
        StayRequestBanner(request: .preview(status: .offered, hostInitiated: true), viewerID: "preview-guest",
                          otherName: "Shai", isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
        // Host's view of their own offer: withdraw.
        StayRequestBanner(request: .preview(status: .offered, hostInitiated: true), viewerID: "preview-host",
                          otherName: "Maya", isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
        // An accepted stay, seen by the host.
        StayRequestBanner(request: .preview(status: .accepted), viewerID: "preview-host",
                          otherName: "Maya", isBusy: false,
                          onCancel: {}, onDecline: {}, onAccept: {})
    }
}

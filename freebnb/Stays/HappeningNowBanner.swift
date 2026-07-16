//
//  HappeningNowBanner.swift
//  freebnb
//
//  The in-app twin of the current-stay Live Activity (feature 21): a persistent
//  banner pinned to the top of the Stays tab whenever a stay is live, so the one
//  stay you're in the middle of is surfaced above everything regardless of which
//  pane (Trips / Listings) you're on. Reuses the same `StayPhase` the Live
//  Activity does, so the on-device and on-Lock-Screen states can never disagree.
//

import SwiftUI

struct HappeningNowBanner: View {
    let stay: StayRequest
    let isHost: Bool
    let phase: StayPhase
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: phase.symbolName)
                    .font(.title3)
                    .foregroundStyle(Color.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.onAccent.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        LiveDot(animated: phase == .underway)
                        Text(phase.statusText(isHost: isHost))
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("\(stay.listingCity) · \(stay.dateRangeText)")
                        .font(.caption)
                        .foregroundStyle(Color.onAccent.opacity(0.85))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.onAccent.opacity(0.7))
            }
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phase.statusText(isHost: isHost)). \(stay.listingCity), \(stay.dateRangeText).")
        .accessibilityHint("Opens your conversation about this stay.")
    }
}

/// A small filled dot that pulses while a stay is under way, echoing the "live"
/// language of the banner. Static (non-pulsing) on the arrival/checkout days so
/// only a genuinely in-progress stay animates.
private struct LiveDot: View {
    let animated: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.onAccent)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.35 : 1)
            .opacity(pulsing ? 0.5 : 1)
            .animation(animated ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulsing)
            .onAppear { if animated { pulsing = true } }
            .accessibilityHidden(true)
    }
}

#Preview {
    let base = Date()
    let stay = StayRequest(
        listingID: "l1",
        listingCity: "Lisbon",
        listingTitle: "Sea-view flat in Alfama",
        listingHostName: "Marta",
        hostUserID: "host",
        guestUserID: "guest",
        checkIn: Calendar.current.date(byAdding: .day, value: -1, to: base)!,
        checkOut: Calendar.current.date(byAdding: .day, value: 3, to: base)!,
        status: .accepted
    )
    return VStack(spacing: 12) {
        HappeningNowBanner(stay: stay, isHost: false, phase: .underway) {}
        HappeningNowBanner(stay: stay, isHost: true, phase: .arrivingToday) {}
        HappeningNowBanner(stay: stay, isHost: false, phase: .checkoutToday) {}
    }
    .padding()
    .background(Color.primaryBackground)
}

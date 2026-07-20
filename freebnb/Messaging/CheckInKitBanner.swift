//
//  CheckInKitBanner.swift
//  freebnb
//
//  The arrival essentials (feature 44), pinned to the top of the thread with the
//  host once a stay is close enough to need them.
//
//  The thread is where a guest already goes on arrival day — to say "just landed"
//  or "running late" — so it is where the door code should be, rather than three
//  taps away on the listing page. Collapsed by default: a wifi password sitting
//  permanently open above a conversation is a shoulder-surfing problem, and the
//  guest usually opens this once.
//

import SwiftUI

struct CheckInKitBanner: View {
    let kit: CheckInKit

    @State private var isExpanded = false

    /// Shown from the day before check-in through checkout. Earlier than that the
    /// details are noise on a conversation about whether the dates even work, and
    /// after checkout they are somebody's address left on screen for no reason.
    static func isRelevant(_ kit: CheckInKit, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let opensAt = calendar.date(byAdding: .day, value: -1, to: kit.checkIn) ?? kit.checkIn
        return now >= opensAt && now <= kit.checkOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundColor(Color.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Getting in")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(isExpanded ? "Saved on this phone" : "Door code, wifi, and address")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide arrival details" : "Show arrival details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let street = kit.street {
                        row(icon: "mappin.and.ellipse", title: "Address", value: street)
                    }
                    if let instructions = kit.checkInInstructions {
                        row(icon: "door.left.hand.open", title: "Check-in", value: instructions)
                    }
                    if let keys = kit.keyHandoff {
                        row(icon: "hand.raised", title: "Keys", value: keys)
                    }
                    let wifi = [kit.wifiNetwork, kit.wifiPassword].compactMap { $0 }.joined(separator: " · ")
                    if !wifi.isEmpty {
                        row(icon: "wifi", title: "Wifi", value: wifi)
                    }
                    if let phone = kit.hostPhone {
                        row(icon: "phone", title: "Host phone", value: phone)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accent.opacity(0.07))
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(Color.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundColor(.secondaryText)
                Text(value)
                    .font(.subheadline)
                    // The guest is copying this into a keypad or a wifi sheet.
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

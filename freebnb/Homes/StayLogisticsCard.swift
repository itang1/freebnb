//
//  StayLogisticsCard.swift
//  freebnb
//
//  The post-acceptance surfaces on a listing detail page (feature 19):
//   - guests with a confirmed stay see a logistics card (dates, add-to-Calendar,
//     and the host's house manual once it exists),
//   - hosts see an entry point to edit that manual.
//

import SwiftUI

// MARK: - Guest: confirmed-stay logistics

struct StayLogisticsCard: View {
    let stay: StayRequest
    let home: Home
    let manual: HouseManual?
    let location: ListingLocation?

    @Environment(CheckInKitStore.self) private var checkInKitStore

    private var manualContent: HouseManual? {
        guard let manual, !manual.isEmpty else { return nil }
        return manual
    }

    /// The saved-to-disk copy of this stay's arrival essentials (feature 44).
    private var kit: CheckInKit? { checkInKitStore.kit(for: stay.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.success)
                Text("Your stay is confirmed")
                    .font(.headline)
            }

            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundColor(Color.accent)
                Text("\(AppDateFormatters.mediumDate.string(from: stay.checkIn)) – \(AppDateFormatters.mediumDate.string(from: stay.checkOut))")
                    .font(.subheadline)
                Spacer()
                Text("\(stay.nights) night\(stay.nights == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            if let arrival = stay.arrivalWindow {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundColor(Color.accent)
                    Text("Arrival: \(arrival.displayName)")
                        .font(.subheadline)
                    Spacer()
                }
            }

            if let calendarFile {
                ShareLink(item: calendarFile) {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
            }

            if let manual = manualContent {
                Divider()
                manualRows(manual)
            } else if let kit, kit.hasContent {
                // The live manual didn't load — most likely there is no network.
                // The saved copy is exactly what this feature exists for, so show
                // it rather than an empty card.
                Divider()
                savedKitRows(kit)
            }

            if kit?.hasContent == true {
                Label("Saved on this phone, so it works without a signal", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.success.opacity(0.12))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func manualRows(_ manual: HouseManual) -> some View {
        Text("House manual")
            .font(.subheadline).fontWeight(.semibold)

        if !manual.checkInInstructions.isEmpty {
            manualRow(icon: "key", title: "Check-in", value: manual.checkInInstructions)
        }
        if !manual.keyHandoff.isEmpty {
            manualRow(icon: "hand.raised", title: "Keys", value: manual.keyHandoff)
        }
        if !manual.wifiNetwork.isEmpty || !manual.wifiPassword.isEmpty {
            let wifi = [manual.wifiNetwork, manual.wifiPassword]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            manualRow(icon: "wifi", title: "Wifi", value: wifi)
        }
        if !manual.houseNotes.isEmpty {
            manualRow(icon: "note.text", title: "Notes", value: manual.houseNotes)
        }
        if !manual.hostPhone.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "phone")
                    .frame(width: 20)
                    .foregroundColor(Color.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Host phone").font(.caption).foregroundColor(.secondaryText)
                    if let telURL = URL(string: "tel://\(manual.hostPhone.filter { $0.isNumber || $0 == "+" })") {
                        Link(manual.hostPhone, destination: telURL)
                            .font(.subheadline)
                    } else {
                        Text(manual.hostPhone).font(.subheadline)
                    }
                }
            }
        }
    }

    /// The same rows as `manualRows`, read from the on-disk kit instead of the
    /// live document, for when the live one couldn't be fetched.
    @ViewBuilder
    private func savedKitRows(_ kit: CheckInKit) -> some View {
        Text("House manual")
            .font(.subheadline).fontWeight(.semibold)

        if let street = kit.street {
            manualRow(icon: "mappin.and.ellipse", title: "Address", value: street)
        }
        if let instructions = kit.checkInInstructions {
            manualRow(icon: "key", title: "Check-in", value: instructions)
        }
        if let keys = kit.keyHandoff {
            manualRow(icon: "hand.raised", title: "Keys", value: keys)
        }
        let wifi = [kit.wifiNetwork, kit.wifiPassword].compactMap { $0 }.joined(separator: " · ")
        if !wifi.isEmpty {
            manualRow(icon: "wifi", title: "Wifi", value: wifi)
        }
        if let phone = kit.hostPhone {
            manualRow(icon: "phone", title: "Host phone", value: phone)
        }
    }

    private func manualRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundColor(.secondaryText)
                Text(value).font(.subheadline)
            }
        }
    }

    /// Builds the .ics once per stay so the ShareLink has a file to hand off.
    private var calendarFile: URL? {
        let area = "\(home.address.city), \(home.address.state)"
        let place: String
        if let street = location?.street, !street.isEmpty {
            place = "\(street), \(area)"
        } else {
            place = area
        }
        return CalendarInvite.icsFile(
            uid: stay.id,
            title: "FreeBNB stay with \(home.hostName)",
            location: place,
            notes: manualContent?.checkInInstructions,
            startDay: stay.checkIn,
            endDay: stay.checkOut
        )
    }
}

// MARK: - Host: house-manual entry point

struct HouseManualHostCard: View {
    let manual: HouseManual?
    let onEdit: () -> Void

    private var isEmpty: Bool { manual?.isEmpty ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .foregroundColor(Color.accent)
                Text("House manual")
                    .font(.headline)
            }
            Text(isEmpty
                 ? "Add check-in instructions, wifi, and house notes. Accepted guests see them here."
                 : "Your check-in guide is set. Accepted guests can see it on this listing.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)

            Button(action: onEdit) {
                Label(isEmpty ? "Add house manual" : "Edit house manual", systemImage: "pencil")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accent.opacity(0.12))
                    .foregroundColor(Color.accent)
                    .cornerRadius(10)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondaryText.opacity(0.07))
        .cornerRadius(12)
    }
}

#Preview("Guest logistics") {
    ScrollView {
        StayLogisticsCard(
            stay: PreviewData.stay,
            home: PreviewData.home,
            manual: PreviewData.manual,
            location: PreviewData.location
        )
        .padding()
    }
}

#Preview("Host manual card") {
    HouseManualHostCard(manual: PreviewData.manual, onEdit: {})
        .padding()
}

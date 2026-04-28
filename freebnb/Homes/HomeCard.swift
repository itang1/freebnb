//
//  HomeCard.swift
//  freebnb
//

import SwiftUI

@ViewBuilder
private func AmenityRow<Content: View>(
    isVisible: Bool,
    @ViewBuilder content: () -> Content
) -> some View {
    if isVisible {
        HStack(spacing: 8) { content() }
    }
}


struct HomeCard: View {
    let listing: Home

    private let cardImageHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — photo if available, teal strip otherwise
            header

            // Body
            VStack(alignment: .leading, spacing: 10) {
                // Summary pills
                HStack(spacing: 6) {
                    SummaryPill(icon: "door.left.hand.open", text: "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")")
                    SummaryPill(icon: "person.fill", text: "\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")")
                    SummaryPill(icon: "calendar", text: "up to \(listing.guestPolicy.maxStayDays) night\(listing.guestPolicy.maxStayDays == 1 ? "" : "s")")
                }
                .accessibilityElement(children: .combine)

                if let avail = availabilityLabel {
                    HStack(spacing: 4) {
                        Image(systemName: avail.icon)
                            .font(.caption2)
                        Text(avail.text)
                            .font(.caption)
                    }
                    .foregroundColor(avail.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(avail.color.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(avail.text)
                }

                // Amenity icons in colored chips
                VStack(alignment: .leading, spacing: 8) {
                    // MARK: Guests, Space & Laundry
                    AmenityRow(
                        isVisible: listing.guestPolicy.kidsAllowed ||
                                   listing.guestPolicy.guestPetsAllowed ||
                                   listing.amenities.hostHasPets ||
                                   listing.amenities.hasPrivateGuestBathroom ||
                                   listing.amenities.hasInUnitLaundry ||
                                   listing.amenities.hasCoinLaundryNearby
                    ) {
                        if listing.guestPolicy.kidsAllowed {
                            ChipIcon(systemName: "figure.2.and.child.holdinghands", color: .purple, label: "Kids allowed")
                        }
                        if listing.guestPolicy.guestPetsAllowed {
                            ChipIcon(systemName: "pawprint.fill", color: .purple, label: "Guest pets allowed")
                        }
                        if listing.amenities.hostHasPets {
                            ChipIcon(systemName: "pet.carrier.fill", color: .purple, label: "Host has pets")
                        }
                        if listing.amenities.hasPrivateGuestBathroom {
                            ChipIcon(systemName: "toilet.fill", color: .purple, label: "Private guest bathroom")
                        }
                        if listing.amenities.hasInUnitLaundry {
                            ChipIcon(systemName: "washer.fill", color: .purple, label: "In-unit laundry")
                        }
                        if listing.amenities.hasCoinLaundryNearby {
                            ChipIcon(systemName: "washer.circle.fill", color: .purple, label: "Coin laundry nearby")
                        }
                    }

                    // MARK: Comfort & Amenities
                    AmenityRow(
                        isVisible: listing.amenities.hasAC ||
                                   listing.amenities.hasHeating ||
                                   listing.amenities.hasKitchen ||
                                   listing.amenities.hasFridgeSpace ||
                                   listing.amenities.hasMicrowave ||
                                   listing.amenities.hasTV ||
                                   listing.amenities.hasWifi
                    ) {
                        if listing.amenities.hasAC {
                            ChipIcon(systemName: "snowflake", color: .blue, label: "Air conditioning")
                        }
                        if listing.amenities.hasHeating {
                            ChipIcon(systemName: "heat.waves", color: .blue, label: "Heating")
                        }
                        if listing.amenities.hasKitchen {
                            ChipIcon(systemName: "stove", color: .blue, label: "Kitchen")
                        }
                        if listing.amenities.hasFridgeSpace {
                            ChipIcon(systemName: "refrigerator.fill", color: .blue, label: "Fridge space")
                        }
                        if listing.amenities.hasMicrowave {
                            ChipIcon(systemName: "microwave.fill", color: .blue, label: "Microwave")
                        }
                        if listing.amenities.hasTV {
                            ChipIcon(systemName: "tv.fill", color: .blue, label: "TV")
                        }
                        if listing.amenities.hasWifi {
                            ChipIcon(systemName: "wifi", color: .blue, label: "WiFi")
                        }
                    }

                    // MARK: Provisions
                    AmenityRow(
                        isVisible: listing.amenities.providesPillows ||
                                   listing.amenities.providesBlankets ||
                                   listing.amenities.providesTowels ||
                                   listing.amenities.providesToiletries
                    ) {
                        if listing.amenities.providesPillows {
                            ChipIcon(systemName: "bed.double.fill", color: Color.coral, label: "Pillows provided")
                        }
                        if listing.amenities.providesBlankets {
                            ChipIcon(systemName: "square.stack.fill", color: Color.coral, label: "Blankets provided")
                        }
                        if listing.amenities.providesTowels {
                            ChipIcon(systemName: "shower.fill", color: Color.coral, label: "Towels provided")
                        }
                        if listing.amenities.providesToiletries {
                            ChipIcon(systemName: "bubbles.and.sparkles.fill", color: Color.coral, label: "Toiletries provided")
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.skyBlue.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.appTeal.opacity(0.15), radius: 8, x: 0, y: 5)
    }

    // MARK: - Availability

    private struct AvailabilityLabel {
        let text: String
        let icon: String
        let color: Color
    }

    private var availabilityLabel: AvailabilityLabel? {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let upcoming = (listing.blockedDateRanges ?? []).filter { $0.end > now }
        guard !upcoming.isEmpty else { return nil }
        if upcoming.contains(where: { $0.overlaps(checkIn: now, checkOut: tomorrow) }) {
            return AvailabilityLabel(text: "Unavailable now", icon: "calendar.badge.minus", color: .red)
        }
        return AvailabilityLabel(text: "Some dates blocked", icon: "calendar.badge.exclamationmark", color: .orange)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let firstPhoto = listing.photos.first, let url = URL(string: firstPhoto) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        tealHeaderContent
                    default:
                        Color.appTeal.opacity(0.3)
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(height: cardImageHeight)
                .clipped()

                // Gradient so text is readable over any photo
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                photoHeaderLabel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .frame(height: cardImageHeight)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 20, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 20
            ))
        } else {
            tealHeaderContent
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.appTeal)
        }
    }

    private var photoHeaderLabel: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.hostName)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: listing.hostMotivation.iconName)
                    .font(.caption2)
                Text(listing.hostMotivation.displayName)
                    .font(.caption2)
            }
            .foregroundColor(.white.opacity(0.8))
            .accessibilityLabel("Host motivation: \(listing.hostMotivation.displayName)")
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .accessibilityHidden(true)
        }
    }

    private var tealHeaderContent: some View {
        HStack {
            Image(systemName: "house.fill")
                .font(.subheadline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(listing.hostName)
                    .font(.headline)
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.caption)
                    .opacity(0.85)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: listing.hostMotivation.iconName)
                    .font(.caption2)
                Text(listing.hostMotivation.displayName)
                    .font(.caption2)
            }
            .opacity(0.8)
            .accessibilityLabel("Host motivation: \(listing.hostMotivation.displayName)")

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .opacity(0.8)
                .accessibilityHidden(true)
        }
    }

}

struct SummaryPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appTeal.opacity(0.15))
        .clipShape(Capsule())
    }
}

// Amenity icon in a colored chip
struct ChipIcon: View {
    let systemName: String
    let color: Color
    let label: String

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundColor(color)
            .padding(6)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(label)
    }
}

#Preview {
    HomeCard(listing: Home(
        hostUserID: "preview-host",
        hostName: "Shai",
        address: Address(street: "1257 Lincoln Ave", city: "Pasadena", state: "CA", zip: "91103"),
        description: "Next to the Rose Bowl.",
        contactPreference: .inApp,
        hostMotivation: .eager,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: false, guestPetsAllowed: true),
        amenities: Amenities(
            hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
            hasMicrowave: true, hasTV: true, hasWifi: true,
            hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "Street parking",
            hasInUnitLaundry: true, hasCoinLaundryNearby: false,
            providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: false,
            foodProvision: .some
        )
    ))
}

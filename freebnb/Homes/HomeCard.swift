//
//  HomeCard.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header strip
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

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.appTeal)

            // Body
            VStack(alignment: .leading, spacing: 10) {
                // Summary pills
                HStack(spacing: 6) {
                    SummaryPill(icon: "door.left.hand.open", text: "\(listing.numGuestRooms) room\(listing.numGuestRooms == 1 ? "" : "s")")
                    SummaryPill(icon: "person.fill", text: "\(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s")")
                    SummaryPill(icon: "calendar", text: "up to \(listing.maxStayDays) night\(listing.maxStayDays == 1 ? "" : "s")")
                }
                .accessibilityElement(children: .combine)

                // Amenity icons in colored chips
                VStack(alignment: .leading, spacing: 8) {
                        // MARK: Guests, Space & Laundry
                        AmenityRow(
                            isVisible: listing.kidsAllowed ||
                                       listing.guestPetsAllowed ||
                                       listing.hostHasPets || listing.hasPrivateGuestBathroom ||
                            listing.hasInUnitLaundry ||
                            listing.hasCoinLaundryNearby
                        ) {
                            if listing.kidsAllowed {
                                ChipIcon(systemName: "figure.2.and.child.holdinghands", color: .purple, label: "Kids allowed")
                            }
                            if listing.guestPetsAllowed {
                                ChipIcon(systemName: "pawprint.fill", color: .purple, label: "Guest pets allowed")
                            }
                            if listing.hostHasPets {
                                ChipIcon(systemName: "pet.carrier.fill", color: .purple, label: "Host has pets")
                            }
                            if listing.hasPrivateGuestBathroom {
                                ChipIcon(systemName: "toilet.fill", color: .purple, label: "Private guest bathroom")
                            }
                            if listing.hasInUnitLaundry {
                                ChipIcon(systemName: "washer.fill", color: .purple, label: "In-unit laundry")
                            }
                            if listing.hasCoinLaundryNearby {
                                ChipIcon(systemName: "washer.circle.fill", color: .purple, label: "Coin laundry nearby")
                            }
                        }

                        // MARK: Comfort & Amenities
                        AmenityRow(
                            isVisible: listing.hasAC ||
                                       listing.hasHeating ||
                                       listing.hasKitchen ||
                                       listing.hasFridgeSpace ||
                                       listing.hasMicrowave ||
                                       listing.hasTV ||
                                       listing.hasWifi
                        ) {
                            if listing.hasAC {
                                ChipIcon(systemName: "snowflake", color: .blue, label: "Air conditioning")
                            }
                            if listing.hasHeating {
                                ChipIcon(systemName: "heat.waves", color: .blue, label: "Heating")
                            }
                            if listing.hasKitchen {
                                ChipIcon(systemName: "stove", color: .blue, label: "Kitchen")
                            }
                            if listing.hasFridgeSpace {
                                ChipIcon(systemName: "refrigerator.fill", color: .blue, label: "Fridge space")
                            }
                            if listing.hasMicrowave {
                                ChipIcon(systemName: "microwave.fill", color: .blue, label: "Microwave")
                            }
                            if listing.hasTV {
                                ChipIcon(systemName: "tv.fill", color: .blue, label: "TV")
                            }
                            if listing.hasWifi {
                                ChipIcon(systemName: "wifi", color: .blue, label: "WiFi")
                            }
                        }

                        // MARK: Provisions
                        AmenityRow(
                            isVisible: listing.providesPillows ||
                                       listing.providesBlankets ||
                                       listing.providesTowels ||
                                       listing.providesToiletries
                        ) {
                            if listing.providesPillows {
                                ChipIcon(systemName: "bed.double.fill", color: Color.coral, label: "Pillows provided")
                            }
                            if listing.providesBlankets {
                                ChipIcon(systemName: "square.stack.fill", color: Color.coral, label: "Blankets provided")
                            }
                            if listing.providesTowels {
                                ChipIcon(systemName: "shower.fill", color: Color.coral, label: "Towels provided")
                            }
                            if listing.providesToiletries {
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
    HomeCard(listing: sampleData.randomElement()!)
}


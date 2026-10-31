//
//  HomeDetailSections.swift
//  freebnb
//
//  The read-only fact cards on a listing's detail page: they depend only on the
//  `Home`, so they live apart from the page's state.
//

import SwiftUI

/// Rooms, beds and capacity in one card.
struct ListingSpaceSection: View {
    let home: Home

    var body: some View {
        ListingSection("The space", systemImage: "bed.double") {
            VStack(alignment: .leading, spacing: 8) {
                ListingDetailRow("Guest rooms", "\(home.sleeping.numGuestRooms)")
                // Omitted rather than zero: unanswered, not "none".
                if home.sleeping.numBathrooms > 0 {
                    ListingDetailRow("Bathrooms", "\(home.sleeping.numBathrooms)")
                }
                ListingDetailRow("Sleeps up to", "\(home.guestPolicy.maxGuests)")
                ListingDetailRow(
                    "Longest stay",
                    "\(home.guestPolicy.maxStayDays) night\(home.guestPolicy.maxStayDays == 1 ? "" : "s")"
                )
                if !home.sleeping.sleepingCounts.isEmpty {
                    ListingDetailRow("Sleeping arrangements", home.sleeping.arrangementsDescription)
                }
                if !home.sleeping.bedSizeCounts.isEmpty {
                    ListingDetailRow("Bed sizes", home.sleeping.bedSizesDescription)
                }
            }
        }
    }
}

struct ListingWhoCanComeSection: View {
    let home: Home

    var body: some View {
        ListingSection("Who can come", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 6) {
                ListingAmenityRow("Kids Allowed", available: home.guestPolicy.kidsAllowed)
                ListingAmenityRow("Guest Can Bring Pets", available: home.guestPolicy.guestPetsAllowed)
                ListingAmenityRow("Host Has Pets", available: home.amenities.hostHasPets)
            }
            .font(.subheadline)
        }
    }
}

/// Amenities and rooms/laundry in one card; parking is a footnote.
struct ListingAmenitiesSection: View {
    let home: Home

    var body: some View {
        ListingSection("Amenities", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                ListingAmenityRow("Air Conditioning", available: home.amenities.hasAC)
                ListingAmenityRow("Heating", available: home.amenities.hasHeating)
                ListingAmenityRow("Kitchen", available: home.amenities.hasKitchen)
                ListingAmenityRow("Fridge Space", available: home.amenities.hasFridgeSpace)
                ListingAmenityRow("Microwave", available: home.amenities.hasMicrowave)
                ListingAmenityRow("TV", available: home.amenities.hasTV)
                ListingAmenityRow("Wifi", available: home.amenities.hasWifi)
                ListingAmenityRow("Private Guest Bathroom", available: home.amenities.hasPrivateGuestBathroom)
                ListingAmenityRow("In-unit Laundry", available: home.amenities.hasInUnitLaundry)
                ListingAmenityRow("Coin Laundry Nearby", available: home.amenities.hasCoinLaundryNearby)

                if !home.amenities.parkingDetails.isEmpty {
                    Divider().padding(.vertical, 2)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "car")
                            .foregroundColor(Color.accent)
                            .accessibilityHidden(true)
                        Text(home.amenities.parkingDetails)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Parking: \(home.amenities.parkingDetails)")
                }
            }
            .font(.subheadline)
        }
    }
}

struct ListingProvisionsSection: View {
    let home: Home

    var body: some View {
        ListingSection("What's provided", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 6) {
                ListingAmenityRow("Pillows", available: home.amenities.providesPillows)
                ListingAmenityRow("Blankets", available: home.amenities.providesBlankets)
                ListingAmenityRow("Towels", available: home.amenities.providesTowels)
                ListingAmenityRow("Toiletries", available: home.amenities.providesToiletries)
                HStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .foregroundColor(home.amenities.foodProvision == .none ? .secondaryText.opacity(0.75) : .green)
                        .accessibilityHidden(true)
                    Text("Food: \(home.amenities.foodProvision.displayName)")
                        .foregroundColor(home.amenities.foodProvision == .none ? .secondaryText.opacity(0.75) : .primary)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.subheadline)
        }
    }
}

struct ListingCancellationSection: View {
    let home: Home

    var body: some View {
        let policy = home.cancellationPolicy ?? .flexible
        ListingSection("If plans change", systemImage: "arrow.uturn.backward") {
            VStack(alignment: .leading, spacing: 4) {
                Text(policy.displayName)
                    .font(.subheadline).fontWeight(.medium)
                Text(policy.description)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
    }
}
/// A label/value pair for non-yes/no facts, so they line up as a table.
struct ListingDetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// A yes/no fact: a check when available, a muted cross and "(not available)" when not.
struct ListingAmenityRow: View {
    let label: String
    let available: Bool

    init(_ label: String, available: Bool) {
        self.label = label
        self.available = available
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(available ? .success : .secondaryText.opacity(0.75))
                .accessibilityHidden(true)
            Text(available ? label : "\(label) (not available)")
                .foregroundColor(available ? .primary : .secondaryText.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
    }
}

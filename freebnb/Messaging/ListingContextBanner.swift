//
//  ListingContextBanner.swift
//  freebnb
//
//  Header shown above a chat thread that was opened from a specific listing.
//  Split out of MessagingPage.swift (A2).
//

import SwiftUI

struct ListingContextBanner: View {
    let listing: Home
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.fill")
                .font(.subheadline)
                .foregroundColor(.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Re: \(listing.displayTitle)")
                    .font(.subheadline).fontWeight(.semibold)
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.caption).foregroundColor(.secondaryText)
            }
            Spacer()
            if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .accessibilityLabel("Muted")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accent.opacity(0.07))
    }
}

#Preview {
    ListingContextBanner(
        listing: Home(
            hostUserID: "preview-host",
            hostName: "Shai",
            address: Address(city: "Pasadena", state: "CA", zip: "91103"),
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
        ),
        isMuted: true
    )
}

//
//  HomeCard.swift
//  freebnb
//

import SwiftUI

struct HomeCard: View {
    let listing: Home
    /// Why this listing reached the viewer. Nil for a public listing from outside
    /// the viewer's network, which needs no explanation.
    var reason: FeedReason?
    /// Distance from the city the viewer searched for. Nil when they haven't
    /// searched, or when this listing has no stored coordinate.
    var distanceMiles: Double?

    private let cardImageHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — photo if available, teal strip otherwise
            header

            // Body — the feed card is for scanning; the full amenity breakdown
            // lives on HomeDetailPage, so the card shows only host, place, and the
            // at-a-glance summary pills.
            VStack(alignment: .leading, spacing: 8) {
                // The feed is only ever your listings and your friends', so "from
                // a friend" is a given and goes unlabelled; only your own listings
                // still earn a chip to set them apart from the rest.
                let showReasonChip = reason == .yourListing
                if showReasonChip || distanceMiles != nil {
                    HStack(spacing: 6) {
                        if showReasonChip, let reason {
                            FeedReasonChip(reason: reason)
                        }
                        if let distanceMiles {
                            SummaryPill(icon: "location.fill", text: Geo.distanceText(distanceMiles))
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: listing.hostMotivation.iconName)
                        .font(.caption2)
                    Text(listing.hostMotivation.homeText)
                        .font(.caption)
                }
                .foregroundColor(.accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Host motivation: \(listing.hostMotivation.homeText)")

                // Summary pills
                HStack(spacing: 6) {
                    SummaryPill(icon: "door.left.hand.open", text: "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")")
                    // Zero bathrooms means the host never said, not that there are
                    // none. Say nothing rather than something false.
                    if listing.sleeping.numBathrooms > 0 {
                        SummaryPill(icon: "shower.fill", text: "\(listing.sleeping.numBathrooms) bath\(listing.sleeping.numBathrooms == 1 ? "" : "s")")
                    }
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
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondaryBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.accent.opacity(0.15), radius: 8, x: 0, y: 5)
    }

    // MARK: - Availability

    private struct AvailabilityLabel {
        let text: String
        let icon: String
        let color: Color
    }

    /// One chip, most-specific-first: a hard "not tonight" outranks a general note
    /// that some dates are spoken for. Two chips would compete for the same glance
    /// and the card has no room. A listing with nothing blocked earns no chip: the
    /// card says nothing rather than inventing a promise the host never made.
    private var availabilityLabel: AvailabilityLabel? {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        // Blocked and booked together, so a booked stretch shows "unavailable" the
        // same as a host-blocked one. The card never says which it is; a guest sees
        // a date is taken, not that the home is occupied.
        let upcoming = listing.unavailableRanges.filter { $0.end > now }

        if upcoming.contains(where: { $0.overlaps(checkIn: now, checkOut: tomorrow) }) {
            return AvailabilityLabel(text: "Unavailable now", icon: "calendar.badge.minus", color: .red)
        }
        guard !upcoming.isEmpty else { return nil }
        return AvailabilityLabel(text: "Some dates unavailable", icon: "calendar.badge.exclamationmark", color: .orange)
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
                        Color.accent.opacity(0.3)
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
                .foregroundColor(.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.accent)
        }
    }

    private var photoHeaderLabel: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.hostName)
                    .font(.headline)
                    .foregroundColor(.white)
                if let title = listing.customTitle {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
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
                if let title = listing.customTitle {
                    Text(title)
                        .font(.subheadline)
                        .opacity(0.9)
                        .lineLimit(1)
                }
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
    }

}

/// "Why you're seeing this" (feature 18). Reads as a statement about the graph,
/// so it is announced as one sentence rather than as an icon beside a word.
struct FeedReasonChip: View {
    let reason: FeedReason

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: reason.iconName)
                .font(.caption2)
                .accessibilityHidden(true)
            Text(reason.label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(Color.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accent.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Why you're seeing this: \(reason.label)")
    }
}

/// A spec pill: room / bath / guest counts and distance. The count reads at full
/// strength in the primary text colour so the fact carries weight, while the icon
/// takes brand teal for a spot of colour. Keeping the *text* neutral (rather than
/// the whole pill teal) means a card full of these still lets the "Friend" reason
/// chip and the availability warning stand out.
struct SummaryPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accent.opacity(0.12), in: Capsule())
    }
}

#Preview {
    HomeCard(listing: Home(
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
    ))
}

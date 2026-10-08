//
//  HomeCard.swift
//  freebnb
//

import SwiftUI

struct HomeCard: View {
    let listing: Home
    /// Why this listing reached the viewer; nil needs no explanation.
    var reason: FeedReason?
    /// Distance from the searched city; nil without a search or stored coordinate.
    var distanceMiles: Double?

    private let cardImageHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — photo if available, teal strip otherwise
            header

            // Body: the card is for scanning; the full breakdown is on HomeDetailPage.
            VStack(alignment: .leading, spacing: 8) {
                // Everything here is yours or a friend's, so "from a friend" goes unlabelled; only your own
                // listings get a chip.
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
                    // Zero bathrooms means unsaid, not none; say nothing rather than something false.
                    if listing.sleeping.numBathrooms > 0 {
                        SummaryPill(icon: "shower.fill", text: "\(listing.sleeping.numBathrooms) bath\(listing.sleeping.numBathrooms == 1 ? "" : "s")")
                    }
                    SummaryPill(icon: "person.fill", text: "\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")")
                    SummaryPill(icon: "calendar", text: "up to \(listing.guestPolicy.maxStayDays) night\(listing.guestPolicy.maxStayDays == 1 ? "" : "s")")
                }
                .accessibilityElement(children: .combine)

            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.accent.opacity(0.15), radius: 8, x: 0, y: 5)
    }

    // MARK: - Header
    // No availability chip: dates are a calendar's job, and a chip would fire on every listing or promise a
    // vacancy never offered.

    @ViewBuilder
    private var header: some View {
        if let firstPhoto = listing.photos.first, let url = URL(string: firstPhoto) {
            ZStack(alignment: .bottomLeading) {
                // Downsampled to about the drawn width; a full-size photo decoded mid-scroll stutters the feed.
                CachedAsyncImage(url: url, maxPointSize: 700) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        tealHeaderContent
                    case .empty:
                        Color.accent.opacity(0.3)
                            .overlay(ProgressView().tint(.accent))
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
        HStack(spacing: 10) {
            // A white ring so the avatar holds its shape against a busy photo.
            GeneratedAvatar(seed: listing.hostUserID, size: 36)
                .background(Circle().fill(.thinMaterial))
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))

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
        HStack(spacing: 10) {
            // Photo-less cards used to be an identical teal strip; the host's avatar differs per card, on a
            // light disc since its tints suit the page background.
            GeneratedAvatar(seed: listing.hostUserID, size: 36)
                .background(Circle().fill(Color.primaryBackground))

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

/// "Why you're seeing this": announced as one sentence, not an icon beside a word.
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
        // Shell pink under teal text: the one warm fill, so the social signal stands out from the teal pills.
        .background(Color.tertiaryBackground)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Why you're seeing this: \(reason.label)")
    }
}

/// A spec pill (room / bath / guest counts, distance): text in the primary colour for weight, icon in brand
/// teal, so the "Friend" chip still stands out.
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

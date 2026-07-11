//
//  NetworkRail.swift
//  freebnb
//
//  "New from your network" (feature 10): a horizontal rail of listings your
//  friends and their friends put up in the last couple of weeks, sitting above
//  the feed. Membership and order are decided by `FeedSections`; this file only
//  draws the result.
//

import SwiftUI

struct NetworkRail: View {
    /// Already narrowed to the rail's members, newest first. Callers get this
    /// from `FeedSections.newFromYourNetwork(_:myID:friendIDs:)` and hide the
    /// whole rail when it comes back empty.
    let listings: [Home]
    let viewerID: String
    let friendIDs: Set<String>
    let onSelectHome: (Home) -> Void

    private let cardWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New from your network")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(listings) { listing in
                        Button {
                            onSelectHome(listing)
                        } label: {
                            card(listing)
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityLabel("\(listing.hostName) in \(listing.address.city), \(listing.address.state)")
                        .accessibilityHint("Opens listing details")
                    }
                }
                // Room for the cards' shadows inside the scroll view's clip.
                // Without it they are shaved off at the rail's edges.
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }

    private func card(_ listing: Home) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail(listing)

            VStack(alignment: .leading, spacing: 6) {
                Text(listing.hostName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let reason = FeedSections.reason(for: listing, myID: viewerID, friendIDs: friendIDs) {
                    FeedReasonChip(reason: reason)
                }

                if let createdAt = listing.createdAt {
                    Text(createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: cardWidth, alignment: .leading)
        .background(Color.secondaryBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.accent.opacity(0.15), radius: 6, x: 0, y: 3)
    }

    @ViewBuilder
    private func thumbnail(_ listing: Home) -> some View {
        Group {
            if let first = listing.photos.first, let url = URL(string: first) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        Color.accent.opacity(0.3)
                            .overlay(ProgressView().tint(.white))
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: cardWidth, height: 110)
        .clipped()
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Color.accent
            .overlay(
                Image(systemName: "house.fill")
                    .font(.title2)
                    .foregroundColor(.onAccent.opacity(0.85))
            )
    }
}

#Preview {
    ScrollView {
        NetworkRail(
            listings: PreviewData.homes,
            viewerID: PreviewData.viewerID,
            friendIDs: [PreviewData.friendID],
            onSelectHome: { _ in }
        )
    }
    .background(Color.primaryBackground)
}

//
//  ListingSection.swift
//  freebnb
//
//  The card container every block on HomeDetailPage sits in. The page used to
//  be one long column of bare `Text(...).font(.headline)` headings with the
//  same spacing between a heading and its own rows as between two unrelated
//  blocks, so nothing looked grouped and the whole page read as one list.
//

import SwiftUI

struct ListingSection<Content: View>: View {
    let title: String
    /// Drawn in accent before the title. Optional so a section can stay plain.
    var systemImage: String?
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .foregroundColor(Color.accent)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
            }
            .accessibilityAddTraits(.isHeader)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 14) {
            ListingSection("Amenities", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wifi")
                    Text("Kitchen")
                }
                .font(.subheadline)
            }
            ListingSection("Parking", systemImage: "car") {
                Text("Street parking, free after 6pm.")
                    .font(.subheadline)
            }
        }
        .padding()
    }
    .background(Color.primaryBackground)
}

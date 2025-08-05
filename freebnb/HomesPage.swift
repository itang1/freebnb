//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI

struct HomesPage: View {
    @State private var selectedSort = "None"
    @State private var selectedFilter = "All"

    var listings: [Home]
    var onSelectHome: (Home) -> Void

    var filteredListings: [Home] {
        var result = listings

        if selectedFilter == "Pets Allowed" {
            result = result.filter { $0.petsAllowed }
        }

        switch selectedSort {
        case "Most Guest Rooms":
            return result.sorted { $0.numGuestRooms > $1.numGuestRooms }
        case "Most Guests":
            return result.sorted { $0.maxGuests > $1.maxGuests }
        default:
            return result
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Available FreeBNBs")
                .font(.title)
                .fontWeight(.semibold)

            HStack {
                Menu("Filter: \(selectedFilter)") {
                    Button("All", action: { selectedFilter = "All" })
                    Button("Pet Friendly", action: { selectedFilter = "Pet Friendly" })
                }

                Menu("Sort: \(selectedSort)") {
                    Button("None", action: { selectedSort = "None" })
                    Button("Most Rooms", action: { selectedSort = "Most Rooms" })
                    Button("Most Guests", action: { selectedSort = "Most Guests" })
                }
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredListings) { listing in
                        Button {
                            onSelectHome(listing)
                        } label: {
                            HomeCard(listing: listing)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
            }
        }
        .padding()
        .navigationTitle("Available FreeBNBs")
    }
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

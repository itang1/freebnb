//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//
// Shows a list of Home listings. Lets the user filter them. Lets the user sort them. Tells its parent which home was tapped.


import SwiftUI

// Represents all possible filters. Each case is one filter option, and its string is the value that gets shown in the UI
enum HomeFilter: String, CaseIterable, Identifiable {
    case petsAllowed = "Pets Allowed"
    case privateGuestRoom = "Private Guest Room"

    // creates an id because ForEach needs each item to be uniquely identifiaale
    var id: String { rawValue }
}

// View to define a new SwiftUI screen
struct HomesPage: View {
    @State private var selectedSort = "Default"
    @State private var selectedFilters: Set<HomeFilter> = []

    var listings: [Home]
    var onSelectHome: (Home) -> Void

    // Set of filters
    var filteredListings: [Home] {
        var result = listings

        // Apply filters
        if selectedFilters.contains(.petsAllowed) {
            result = result.filter { $0.petsAllowed }
        }

        if selectedFilters.contains(.privateGuestRoom) {
            result = result.filter { $0.numGuestRooms > 0 }
        }

        // Apply sorting
        switch selectedSort {
        case "Most Rooms":
            return result.sorted { $0.numGuestRooms > $1.numGuestRooms }
        case "Most Guests":
            return result.sorted { $0.maxGuests > $1.maxGuests }
        case "Most Days":
            return result.sorted { $0.maxStayLengthDays > $1.maxStayLengthDays }
        default:
            return result
        }
    }

    var body: some View {
        VStack(spacing: 20) {

            HStack {
                // Filter Menu
                Menu {
                    ForEach(HomeFilter.allCases) { filter in
                        Button {
                            toggleFilter(filter)
                        } label: {
                            Label(
                                filter.rawValue,
                                systemImage: selectedFilters.contains(filter) ? "checkmark" : ""
                            )
                        }
                    }

                    Divider()

                    Button("Clear Filters") {
                        selectedFilters.removeAll()
                    }

                } label: {
                    Text(filterLabel)
                }

                // Sort Menu
                Menu("Sort: \(selectedSort)") {
                    Button("Default") { selectedSort = "Default" }
                    Button("Most Rooms") { selectedSort = "Most Rooms" }
                    Button("Most Guests") { selectedSort = "Most Guests" }
                    Button("Most Days") { selectedSort = "Most Days" }
                }
            }

            // Display the listings
            ScrollView {
                LazyVStack(spacing: 15) {
                    ForEach(filteredListings) { listing in
                        Button {
                            onSelectHome(listing)
                        } label: {
                            HomeCard(listing: listing)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .padding()
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
    }

    // Toggle the filter
    private func toggleFilter(_ filter: HomeFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    private var filterLabel: String {
        selectedFilters.isEmpty
            ? "Filter: All"
            : "Filter: \(selectedFilters.count)"
    }
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

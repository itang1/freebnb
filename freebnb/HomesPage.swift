//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//
//  Shows a list of Home listings. Lets the user filter them. Lets the user sort them. Tells its parent which home was tapped.


import SwiftUI

// Represents all possible filters
enum HomeFilter: String, CaseIterable, Identifiable {
    case hasWifi = "Has Wifi"
    case petsAllowed = "Pets Allowed"
    case privateGuestRoom = "Private Guest Room"
    case inUnitLaundry = "In-unit Laundry"

    var id: String { rawValue }
}

// View to define a new SwiftUI screen
struct HomesPage: View {
    @State private var selectedSort = "Default"
    @State private var selectedFilters: Set<HomeFilter> = []

    var listings: [Home]
    var onSelectHome: (Home) -> Void

    var filteredListings: [Home] {
        var result = listings

        // Apply filters
        if selectedFilters.contains(.hasWifi) {
            result = result.filter { $0.hasWifi }
        }
        if selectedFilters.contains(.petsAllowed) {
            result = result.filter { $0.petsAllowed }
        }
        if selectedFilters.contains(.privateGuestRoom) {
            result = result.filter { $0.numGuestRooms > 0 }
        }
        if selectedFilters.contains(.inUnitLaundry) {
            result = result.filter { $0.hasInUnitLaundry }
        }
        
        // Apply sorting
        switch selectedSort {
            case "Most Days":
                return result.sorted { $0.maxStayLengthDays > $1.maxStayLengthDays }
            case "Most Guests":
                return result.sorted { $0.maxGuests > $1.maxGuests }
            case "Most Rooms":
                return result.sorted { $0.numGuestRooms > $1.numGuestRooms }
            default:
                return result
        }
    }

    var body: some View {
        VStack(spacing: 20) {

            HStack {
                // Display the Filter Menu
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

                // Display the Sort Menu
                Menu("Sort: \(selectedSort)") {
                    Button("Default") { selectedSort = "Default" }
                    Button("Most Rooms") { selectedSort = "Most Rooms" }
                    Button("Most Guests") { selectedSort = "Most Guests" }
                    Button("Most Days") { selectedSort = "Most Days" }
                }
                
            }
            
            // Display the selected filters
            if !selectedFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(selectedFilters)) { filter in
                            Text(filter.rawValue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(20)
                        }
                    }
                }
            }

            ScrollView {
                // Display the listings
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
                
                // Display a message if there are no matching listings
                if filteredListings.isEmpty {
                    Text("No homes match your filters")
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
    }

    // Helper function to toggle the filter
    private func toggleFilter(_ filter: HomeFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    // Helper function to display how many filters are applied
    private var filterLabel: String {
        selectedFilters.isEmpty
            ? "Filters: None"
            : "Filters: \(selectedFilters.count)"
    }
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//
//  Shows a list of Home listings. Lets the user filter them. Lets the user sort them. Tells its parent which home was tapped.

//  TODO: refactor pets variable name, have a calendar availability and way to reserve, create user accounts, store data securely, tips on being a great house guest

import SwiftUI

// All possible filter options
enum FilterOption: String, CaseIterable, Identifiable {
    case guestRooms = "Guest has Private Room"
    case kidsAllowed = "Kids Allowed"
    case petsOfGuests = "Guest May Bring Pets"
    case petsHost = "Host has Pets"
    case privateGuestBathroom = "Private Guest Bathroom"
    case inUnitLaundry = "In-unit Laundry"
    case coinLaundryNearby = "Coin Laundry Nearby"
    case airConditioning = "Air Conditioning"
    case heating = "Heating"
    case kitchen = "Kitchen"
    case fridgeSpace = "Fridge Space"
    case tv = "TV"
    case wifi = "Wifi"
    case microwave = "Microwave"
    case sleepingBed = "Guest has Bed"
    case pillowsProvided = "Pillows Provided"
    case blanketsProvided = "Blankets Provided"
    case towelsProvided = "Towels Provided"
    case toiletriesProvided = "Toiletries Provided"
    
    var id: String { rawValue }
    
    func applies(to home: Home) -> Bool {
        switch self {
        case .guestRooms:
            return home.numGuestRooms > 0
        case .kidsAllowed:
            return home.kidsAllowed
        case .petsOfGuests:
            return home.petsAllowed
        case .petsHost:
            return home.petsOnPremises
        case .privateGuestBathroom:
            return home.hasPrivateGuestBathroom
        case .inUnitLaundry:
            return home.hasInUnitLaundry
        case .coinLaundryNearby:
            return home.hasCoinLaundry
        case .airConditioning:
            return home.hasAC
        case .heating:
            return home.hasHeating
        case .kitchen:
            return home.hasKitchen
        case .fridgeSpace:
            return home.hasFridgeSpace
        case .tv:
            return home.hasTV
        case .wifi:
            return home.hasWifi
        case .microwave:
            return home.hasMicrowave
        case .sleepingBed:
            return (home.sleepingArrangements[.bed] ?? 0) > 0
        case .pillowsProvided:
            return home.providesPillows
        case .blanketsProvided:
            return home.providesBlankets
        case .towelsProvided:
            return home.providesTowels
        case .toiletriesProvided:
            return home.providesToiletries
        }
    }
}


// All possible sort options
enum SortOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case mostRooms = "Most Rooms"
    case mostGuests = "Most Guests"
    case mostDays = "Most Days"

    var id: String { rawValue }
}


// View to define a new SwiftUI screen
struct HomesPage: View {
    @State private var selectedFilters: Set<FilterOption> = []
    @State private var selectedSort: SortOption = .default

    var listings: [Home]
    var onSelectHome: (Home) -> Void

    var filteredListings: [Home] {
        var result = listings

        // Apply filters
        for filter in selectedFilters {
            result = result.filter { filter.applies(to: $0) }
        }
        
        // Apply sorting
        switch selectedSort {
        case .mostDays:
            return result.sorted { $0.maxStayLengthDays > $1.maxStayLengthDays }
        case .mostGuests:
            return result.sorted { $0.maxGuests > $1.maxGuests }
        case .mostRooms:
            return result.sorted { $0.numGuestRooms > $1.numGuestRooms }
        default:
            return result
        }
    }

    var body: some View {
        VStack(spacing: 20) {

            HStack {
                // Display the Filter Menu
                Menu(filterLabel) {
                    ForEach(FilterOption.allCases) { filter in
                        Toggle(
                            filter.rawValue,
                            isOn: Binding(
                                get: { selectedFilters.contains(filter) },
                                set: { isOn in
                                    if isOn {
                                        selectedFilters.insert(filter)
                                    } else {
                                        selectedFilters.remove(filter)
                                    }
                                }
                            )
                        )
                    }

                    Divider()

                    Button("Clear Filters") {
                        selectedFilters.removeAll()
                    }
                }
                #if os(iOS) || os(tvOS) || os(visionOS)
                .menuActionDismissBehavior(.disabled)
                #endif
                
                Text("|")

                // Display the Sort Menu
                Menu ("Sort: \(selectedSort.rawValue)") {
                    Button("Default") { selectedSort = .default }
                    Button("Most Rooms") { selectedSort = .mostRooms }
                    Button("Most Guests") { selectedSort = .mostGuests }
                    Button("Most Days") { selectedSort = .mostDays }
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
                        .padding()
                }
            }
        }
        .padding()
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
    }

    // Helper function to toggle the filter
    private func toggleFilter(_ filter: FilterOption) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    // Helper function to display the filter menu
    private var filterLabel: String {
        selectedFilters.isEmpty
            ? "Filters: None"
            : "Filters: \(selectedFilters.count)"
    }
    
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

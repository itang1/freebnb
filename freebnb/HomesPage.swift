//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//
//  Shows a list of Home listings. Lets the user filter them. Lets the user sort them. Tells its parent which home was tapped.

//  TODO: have a calendar availability and way to reserve, create user accounts, store data securely

import SwiftUI

// Filter categories matching the Home model structure
enum FilterCategory: String, CaseIterable {
    case guestsAndSpace = "Guests & Space"
    case amenities = "Amenities"
    case roomsAndLaundry = "Rooms & Laundry"
    case provisions = "Provisions"
}

// All possible filter options, ordered to match Home model declaration
enum FilterOption: String, CaseIterable, Identifiable {
    // Guests & Space (Home model: Capacity)
    case guestRooms = "Guest has Private Room"
    case sleepingBed = "Guest has Bed"
    case kidsAllowed = "Kids Allowed"
    case guestPetsAllowed = "Guest Can Bring Pets"
    case hostHasPets = "Host Has Pets"

    // Amenities (Home model: Comfort and amenities)
    case airConditioning = "Air Conditioning"
    case heating = "Heating"
    case kitchen = "Kitchen"
    case fridgeSpace = "Fridge Space"
    case microwave = "Microwave"
    case tv = "TV"
    case wifi = "Wifi"

    // Rooms & Laundry (Home model: Other rooms)
    case privateGuestBathroom = "Private Guest Bathroom"
    case inUnitLaundry = "In-unit Laundry"
    case coinLaundryNearby = "Coin Laundry Nearby"

    // Provisions (Home model: Provisions)
    case pillowsProvided = "Pillows Provided"
    case blanketsProvided = "Blankets Provided"
    case towelsProvided = "Towels Provided"
    case toiletriesProvided = "Toiletries Provided"

    var id: String { rawValue }

    var category: FilterCategory {
        switch self {
        case .guestRooms, .sleepingBed, .kidsAllowed, .guestPetsAllowed, .hostHasPets:
            return .guestsAndSpace
        case .airConditioning, .heating, .kitchen, .fridgeSpace, .microwave, .tv, .wifi:
            return .amenities
        case .privateGuestBathroom, .inUnitLaundry, .coinLaundryNearby:
            return .roomsAndLaundry
        case .pillowsProvided, .blanketsProvided, .towelsProvided, .toiletriesProvided:
            return .provisions
        }
    }

    static func options(for category: FilterCategory) -> [FilterOption] {
        allCases.filter { $0.category == category }
    }

    func applies(to home: Home) -> Bool {
        switch self {
        case .guestRooms:
            return home.numGuestRooms > 0
        case .sleepingBed:
            return (home.sleepingArrangements[.bed] ?? 0) > 0
        case .kidsAllowed:
            return home.kidsAllowed
        case .guestPetsAllowed:
            return home.guestPetsAllowed
        case .hostHasPets:
            return home.hostHasPets
        case .airConditioning:
            return home.hasAC
        case .heating:
            return home.hasHeating
        case .kitchen:
            return home.hasKitchen
        case .fridgeSpace:
            return home.hasFridgeSpace
        case .microwave:
            return home.hasMicrowave
        case .tv:
            return home.hasTV
        case .wifi:
            return home.hasWifi
        case .privateGuestBathroom:
            return home.hasPrivateGuestBathroom
        case .inUnitLaundry:
            return home.hasInUnitLaundry
        case .coinLaundryNearby:
            return home.hasCoinLaundryNearby
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
            return result.sorted { $0.maxStayDays > $1.maxStayDays }
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
                // Display the Filter Menu with category sections
                Menu(filterLabel) {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(FilterOption.options(for: category)) { filter in
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
                        }
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
                Menu("Sort: \(selectedSort.rawValue)") {
                    Button("Default") { selectedSort = .default }
                    Button("Most Rooms") { selectedSort = .mostRooms }
                    Button("Most Guests") { selectedSort = .mostGuests }
                    Button("Most Days") { selectedSort = .mostDays }
                }
            }

            // Display the selected filters as wrapping chips
            if !selectedFilters.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(sortedSelectedFilters) { filter in
                        HStack(spacing: 4) {
                            Text(filter.rawValue)
                                .font(.caption)
                            Button {
                                selectedFilters.remove(filter)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appTeal.opacity(0.2))
                        .cornerRadius(20)
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
        .padding(30)
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
    }

    // Selected filters sorted in the same order as the menu
    private var sortedSelectedFilters: [FilterOption] {
        FilterOption.allCases.filter { selectedFilters.contains($0) }
    }

    // Helper to display the filter menu label
    private var filterLabel: String {
        selectedFilters.isEmpty
            ? "Filters: None"
            : "Filters: \(selectedFilters.count)"
    }
    
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

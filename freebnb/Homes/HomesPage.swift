//
//  HomesPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//  Shows a list of Home listings. Lets the user filter them. Lets the user sort them. Tells its parent which home was tapped.

import SwiftUI

enum FilterCategory: String, CaseIterable {
    case guestsAndSpace = "Guests & Space"
    case amenities = "Amenities"
    case roomsAndLaundry = "Rooms & Laundry"
    case provisions = "Provisions"
    case food = "Food"
}

// All possible filter options, ordered to match Home model declaration
enum FilterOption: String, CaseIterable, Identifiable {
    // Guests & Space
    case guestRooms = "Guest has Private Room"
    case sleepingBed = "Guest has Bed"
    case kidsAllowed = "Kids Allowed"
    case guestPetsAllowed = "Guest Can Bring Pets"
    case hostHasPets = "Host Has Pets"

    // Amenities
    case airConditioning = "Air Conditioning"
    case heating = "Heating"
    case kitchen = "Kitchen"
    case fridgeSpace = "Fridge Space"
    case microwave = "Microwave"
    case tv = "TV"
    case wifi = "Wifi"

    // Rooms & Laundry
    case privateGuestBathroom = "Private Guest Bathroom"
    case inUnitLaundry = "In-unit Laundry"
    case coinLaundryNearby = "Coin Laundry Nearby"

    // Provisions
    case pillowsProvided = "Pillows Provided"
    case blanketsProvided = "Blankets Provided"
    case towelsProvided = "Towels Provided"
    case toiletriesProvided = "Toiletries Provided"

    // Food
    case foodAll = "All Meals Provided"
    case foodSome = "Some Food Provided"
    case foodBareMinimum = "Bare Minimum Provided"
    case foodNone = "No Food Provided"

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
        case .foodAll, .foodSome, .foodBareMinimum, .foodNone:
            return .food
        }
    }

    static func options(for category: FilterCategory) -> [FilterOption] {
        allCases.filter { $0.category == category }
    }

    func applies(to home: Home) -> Bool {
        switch self {
        case .guestRooms:          return home.numGuestRooms > 0
        case .sleepingBed:         return (home.sleepingCounts[.bed] ?? 0) > 0
        case .kidsAllowed:         return home.kidsAllowed
        case .guestPetsAllowed:    return home.guestPetsAllowed
        case .hostHasPets:         return home.hostHasPets
        case .airConditioning:     return home.hasAC
        case .heating:             return home.hasHeating
        case .kitchen:             return home.hasKitchen
        case .fridgeSpace:         return home.hasFridgeSpace
        case .microwave:           return home.hasMicrowave
        case .tv:                  return home.hasTV
        case .wifi:                return home.hasWifi
        case .privateGuestBathroom: return home.hasPrivateGuestBathroom
        case .inUnitLaundry:       return home.hasInUnitLaundry
        case .coinLaundryNearby:   return home.hasCoinLaundryNearby
        case .pillowsProvided:     return home.providesPillows
        case .blanketsProvided:    return home.providesBlankets
        case .towelsProvided:      return home.providesTowels
        case .toiletriesProvided:  return home.providesToiletries
        case .foodAll:             return home.foodProvision == .all
        case .foodSome:            return home.foodProvision == .some
        case .foodBareMinimum:     return home.foodProvision == .bareMinimum
        case .foodNone:            return home.foodProvision == .none
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case mostRooms = "Most Rooms"
    case mostGuests = "Most Guests"
    case mostDays = "Most Days"

    var id: String { rawValue }
}

struct HomesPage: View {
    @State private var selectedFilters: Set<FilterOption> = []
    @State private var selectedSort: SortOption = .default
    // Stable shuffle: we track the desired display order as an array of IDs, then
    // derive the display list from live `listings`. This means content edits to
    // existing listings always propagate immediately (computed from live data),
    // while additions/removals update the ID order.
    @State private var shuffleOrder: [String] = []

    var listings: [Home]
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = false
    var error: String? = nil
    var onLoadMore: () -> Void = {}
    var onSelectHome: (Home) -> Void

    private var shuffledListings: [Home] {
        let byID = Dictionary(uniqueKeysWithValues: listings.map { ($0.id, $0) })
        var result = shuffleOrder.compactMap { byID[$0] }
        let seen = Set(shuffleOrder)
        result += listings.filter { !seen.contains($0.id) }
        return result
    }

    private var filteredListings: [Home] {
        let result = shuffledListings.filter { home in
            selectedFilters.allSatisfy { $0.applies(to: home) }
        }
        switch selectedSort {
        case .mostDays:   return result.sorted { $0.maxStayDays > $1.maxStayDays }
        case .mostGuests: return result.sorted { $0.maxGuests > $1.maxGuests }
        case .mostRooms:  return result.sorted { $0.numGuestRooms > $1.numGuestRooms }
        default:          return result
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }

            HStack {
                Menu {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(FilterOption.options(for: category)) { filter in
                                Toggle(
                                    filter.rawValue,
                                    isOn: Binding(
                                        get: { selectedFilters.contains(filter) },
                                        set: { isOn in
                                            if isOn { selectedFilters.insert(filter) }
                                            else { selectedFilters.remove(filter) }
                                        }
                                    )
                                )
                            }
                        }
                    }
                    Divider()
                    Button("Clear Filters") { selectedFilters.removeAll() }
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appTeal.opacity(0.15), in: Capsule())
                        .foregroundColor(Color.appTeal)
                }
                #if os(iOS) || os(tvOS) || os(visionOS)
                .menuActionDismissBehavior(.disabled)
                #endif

                Menu {
                    Button("Default") { selectedSort = .default }
                    Button("Most Rooms") { selectedSort = .mostRooms }
                    Button("Most Guests") { selectedSort = .mostGuests }
                    Button("Most Days") { selectedSort = .mostDays }
                } label: {
                    Label(selectedSort == .default ? "Sort" : "Sort: \(selectedSort.rawValue)", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appTeal.opacity(0.15), in: Capsule())
                        .foregroundColor(Color.appTeal)
                }
                .transaction { t in t.animation = nil }

                Spacer()
            }

            HStack {
                if !selectedFilters.isEmpty || selectedSort != .default {
                    Button {
                        selectedFilters.removeAll()
                        selectedSort = .default
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                let count = filteredListings.count
                Text("\(count) home\(count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

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
                            .accessibilityLabel("Remove \(filter.rawValue) filter")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appTeal.opacity(0.2))
                        .cornerRadius(20)
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 15) {
                    ForEach(filteredListings) { listing in
                        Button {
                            onSelectHome(listing)
                        } label: {
                            HomeCard(listing: listing)
                        }
                        .buttonStyle(CardButtonStyle())
                        .accessibilityLabel("\(listing.hostName), \(listing.address.city), \(listing.address.state)")
                    }

                    if canLoadMore && !filteredListings.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { onLoadMore() }
                    }

                    if isLoadingMore {
                        ProgressView()
                            .padding(.vertical, 16)
                    }
                }

                if isLoading {
                    VStack(spacing: 16) {
                        Spacer().frame(height: 60)
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading listings...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if filteredListings.isEmpty {
                    VStack(spacing: 16) {
                        Spacer().frame(height: 40)
                        Image(systemName: "house.lodge.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.appTeal.opacity(0.4), Color.appTeal],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("No homes found")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(selectedFilters.isEmpty ? "No listings yet. Check back soon!" : "Try removing some filters to see more results!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        if !selectedFilters.isEmpty {
                            Button("Clear All Filters") { selectedFilters.removeAll() }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.appTeal)
                        }
                    }
                    .padding()
                }
            }
        }
        .padding(30)
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
        .onAppear {
            if shuffleOrder.isEmpty && !listings.isEmpty {
                shuffleOrder = listings.map { $0.id }.shuffled()
            }
        }
        .onChange(of: listings.map { $0.id }) { _, newIDs in
            let newIDSet = Set(newIDs)
            shuffleOrder = shuffleOrder.filter { newIDSet.contains($0) }
            let seen = Set(shuffleOrder)
            let added = newIDs.filter { !seen.contains($0) }.shuffled()
            shuffleOrder.append(contentsOf: added)
        }
    }

    // Selected filters sorted in the same order as the filter menu
    private var sortedSelectedFilters: [FilterOption] {
        FilterOption.allCases.filter { selectedFilters.contains($0) }
    }

    private var filterLabel: String {
        selectedFilters.isEmpty ? "Filter" : "Filter (\(selectedFilters.count))"
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    HomesPage(listings: sampleData, onSelectHome: { _ in })
}

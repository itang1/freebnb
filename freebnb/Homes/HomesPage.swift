//
//  HomesPage.swift
//  freebnb
//
//  Shows a list of Home listings. Lets the user filter them. Lets the user
//  sort them. Tells its parent which home was tapped.
//

import SwiftUI

enum FilterCategory: String, CaseIterable {
    case host = "Host"
    case guestsAndSpace = "Guests & Space"
    case amenities = "Amenities"
    case roomsAndLaundry = "Rooms & Laundry"
    case provisions = "Provisions"
    case food = "Food"
}

// A filter is a (label, category, predicate) triple. Adding a new filter
// means one line in `FilterOption.all` instead of edits in three places.
struct FilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let category: FilterCategory
    let matches: @Sendable (Home) -> Bool

    static func == (lhs: FilterOption, rhs: FilterOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension FilterOption {
    // Convenience for the common "this Bool field on Home" case.
    fileprivate static func bool(
        _ id: String,
        _ label: String,
        _ category: FilterCategory,
        _ keyPath: KeyPath<Home, Bool>
    ) -> FilterOption {
        FilterOption(id: id, label: label, category: category) { $0[keyPath: keyPath] }
    }

    fileprivate static func food(
        _ id: String,
        _ label: String,
        _ value: FoodProvision
    ) -> FilterOption {
        FilterOption(id: id, label: label, category: .food) { $0.foodProvision == value }
    }

    // Source of truth. Declaration order drives menu order and chip order.
    static let all: [FilterOption] = [
        // Host motivation
        FilterOption(id: "eager",     label: "Eager to Host",   category: .host) { $0.hostMotivation == .eager },
        FilterOption(id: "open",      label: "Open to Hosting", category: .host) { $0.hostMotivation == .open },
        FilterOption(id: "selective", label: "Selective",       category: .host) { $0.hostMotivation == .selective },

        // Guests & Space
        FilterOption(id: "guestRoom", label: "Guest has Private Room", category: .guestsAndSpace) { $0.numGuestRooms > 0 },
        FilterOption(id: "sleepingBed", label: "Guest has Bed", category: .guestsAndSpace) { ($0.sleepingCounts[.bed] ?? 0) > 0 },
        .bool("kidsAllowed", "Kids Allowed", .guestsAndSpace, \.kidsAllowed),
        .bool("guestPetsAllowed", "Guest Can Bring Pets", .guestsAndSpace, \.guestPetsAllowed),
        .bool("hostHasPets", "Host Has Pets", .guestsAndSpace, \.hostHasPets),

        // Amenities
        .bool("ac", "Air Conditioning", .amenities, \.hasAC),
        .bool("heating", "Heating", .amenities, \.hasHeating),
        .bool("kitchen", "Kitchen", .amenities, \.hasKitchen),
        .bool("fridgeSpace", "Fridge Space", .amenities, \.hasFridgeSpace),
        .bool("microwave", "Microwave", .amenities, \.hasMicrowave),
        .bool("tv", "TV", .amenities, \.hasTV),
        .bool("wifi", "Wifi", .amenities, \.hasWifi),

        // Rooms & Laundry
        .bool("privateGuestBathroom", "Private Guest Bathroom", .roomsAndLaundry, \.hasPrivateGuestBathroom),
        .bool("inUnitLaundry", "In-unit Laundry", .roomsAndLaundry, \.hasInUnitLaundry),
        .bool("coinLaundryNearby", "Coin Laundry Nearby", .roomsAndLaundry, \.hasCoinLaundryNearby),

        // Provisions
        .bool("pillows", "Pillows Provided", .provisions, \.providesPillows),
        .bool("blankets", "Blankets Provided", .provisions, \.providesBlankets),
        .bool("towels", "Towels Provided", .provisions, \.providesTowels),
        .bool("toiletries", "Toiletries Provided", .provisions, \.providesToiletries),

        // Food
        .food("foodAll", "All Meals Provided", .all),
        .food("foodSome", "Some Food Provided", .some),
        .food("foodBareMinimum", "Bare Minimum Provided", .bareMinimum),
        .food("foodNone", "No Food Provided", FoodProvision.none),
    ]

    static func options(for category: FilterCategory) -> [FilterOption] {
        all.filter { $0.category == category }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case mostEager = "Most Eager"
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
            selectedFilters.allSatisfy { $0.matches(home) }
        }
        switch selectedSort {
        case .mostEager:  return result.sorted { motivationRank($0.hostMotivation) > motivationRank($1.hostMotivation) }
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
                                    filter.label,
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
                    Button("Most Eager") { selectedSort = .mostEager }
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
                            Text(filter.label)
                                .font(.caption)
                            Button {
                                selectedFilters.remove(filter)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityLabel("Remove \(filter.label) filter")
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
                        .accessibilityLabel("\(listing.hostName) in \(listing.address.city), \(listing.address.state)")
                        .accessibilityValue(accessibilitySummary(for: listing))
                        .accessibilityHint("Opens listing details")
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

    // Selected filters sorted in the same order as the filter menu.
    private var sortedSelectedFilters: [FilterOption] {
        FilterOption.all.filter { selectedFilters.contains($0) }
    }

    private var filterLabel: String {
        selectedFilters.isEmpty ? "Filter" : "Filter (\(selectedFilters.count))"
    }

    private func motivationRank(_ m: HostMotivation) -> Int {
        switch m {
        case .eager:    return 2
        case .open:     return 1
        case .selective: return 0
        }
    }

    private func accessibilitySummary(for listing: Home) -> String {
        let rooms = "\(listing.numGuestRooms) room\(listing.numGuestRooms == 1 ? "" : "s")"
        let guests = "\(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s")"
        let nights = "up to \(listing.maxStayDays) night\(listing.maxStayDays == 1 ? "" : "s")"
        return "\(rooms), \(guests), \(nights)"
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
    HomesPage(listings: [], onSelectHome: { _ in })
}

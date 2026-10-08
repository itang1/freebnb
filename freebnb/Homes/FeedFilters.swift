//
//  FeedFilters.swift
//  freebnb
//
//  The feed's filter and sort vocabulary, the pure filterAndSort pipeline and the
//  search-paging state machine, split from HomesPage.swift (FeedOrderingTests, CapacityFacetTests).
//

import SwiftUI

enum FilterCategory: String, CaseIterable {
    case host = "Host"
    case guestsAndSpace = "Guests & Space"
    case accessibility = "Accessibility"
    case amenities = "Amenities"
    case roomsAndLaundry = "Rooms & Laundry"
    case provisions = "Provisions"
    case food = "Food"
    case cancellation = "Cancellation"
}

// A filter is a (label, category, predicate) triple; adding one is a line in `FilterOption.all`.
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
        FilterOption(id: id, label: label, category: .food) { $0.amenities.foodProvision == value }
    }

    fileprivate static func cancellation(
        _ id: String,
        _ label: String,
        _ value: CancellationPolicy
    ) -> FilterOption {
        FilterOption(id: id, label: label, category: .cancellation) {
            ($0.cancellationPolicy ?? .flexible) == value
        }
    }

    // Source of truth; declaration order drives menu and chip order.
    static let all: [FilterOption] = [
        // Host motivation
        FilterOption(id: "notSelective", label: "Available to Host", category: .host) { $0.hostMotivation != .selective },
        FilterOption(id: "eager",     label: "Eager to Host",   category: .host) { $0.hostMotivation == .eager },
        FilterOption(id: "open",      label: "Open to Hosting", category: .host) { $0.hostMotivation == .open },
        FilterOption(id: "selective", label: "Selective",       category: .host) { $0.hostMotivation == .selective },

        // Guests & Space
        FilterOption(id: "guestRoom", label: "Guest has Private Room", category: .guestsAndSpace) { $0.sleeping.numGuestRooms > 0 },
        FilterOption(id: "sleepingBed", label: "Guest has Bed", category: .guestsAndSpace) { ($0.sleeping.sleepingCounts[.bed] ?? 0) > 0 },
        // A listing with no recorded bed size matches neither: a guest filtering for a queen wants more than a maybe.
        FilterOption(id: "bedForTwo", label: "Queen or King Bed", category: .guestsAndSpace) { $0.sleeping.hasBedForTwo },
        FilterOption(id: "twoBathrooms", label: "2+ Bathrooms", category: .guestsAndSpace) { $0.sleeping.numBathrooms >= 2 },
        .bool("kidsAllowed", "Kids Allowed", .guestsAndSpace, \.guestPolicy.kidsAllowed),
        .bool("guestPetsAllowed", "Guest Can Bring Pets", .guestsAndSpace, \.guestPolicy.guestPetsAllowed),
        .bool("hostHasPets", "Host Has Pets", .guestsAndSpace, \.amenities.hostHasPets),

        // Accessibility: each is a host claim, so an absent one filters the listing out.
        .bool("stepFreeEntry", "Step-free Entry", .accessibility, \.amenities.hasStepFreeEntry),
        .bool("elevator", "Elevator", .accessibility, \.amenities.hasElevator),
        .bool("accessibleBathroom", "Accessible Bathroom", .accessibility, \.amenities.hasAccessibleBathroom),

        // Amenities
        .bool("ac", "Air Conditioning", .amenities, \.amenities.hasAC),
        .bool("heating", "Heating", .amenities, \.amenities.hasHeating),
        .bool("kitchen", "Kitchen", .amenities, \.amenities.hasKitchen),
        .bool("fridgeSpace", "Fridge Space", .amenities, \.amenities.hasFridgeSpace),
        .bool("microwave", "Microwave", .amenities, \.amenities.hasMicrowave),
        .bool("tv", "TV", .amenities, \.amenities.hasTV),
        .bool("wifi", "Wifi", .amenities, \.amenities.hasWifi),

        // Rooms & Laundry
        .bool("privateGuestBathroom", "Private Guest Bathroom", .roomsAndLaundry, \.amenities.hasPrivateGuestBathroom),
        .bool("inUnitLaundry", "In-unit Laundry", .roomsAndLaundry, \.amenities.hasInUnitLaundry),
        .bool("coinLaundryNearby", "Coin Laundry Nearby", .roomsAndLaundry, \.amenities.hasCoinLaundryNearby),

        // Provisions
        .bool("pillows", "Pillows Provided", .provisions, \.amenities.providesPillows),
        .bool("blankets", "Blankets Provided", .provisions, \.amenities.providesBlankets),
        .bool("towels", "Towels Provided", .provisions, \.amenities.providesTowels),
        .bool("toiletries", "Toiletries Provided", .provisions, \.amenities.providesToiletries),

        // Food
        .food("foodAll", "All Meals Provided", .all),
        .food("foodSome", "Some Food Provided", .some),
        .food("foodBareMinimum", "Bare Minimum Provided", .bareMinimum),
        .food("foodNone", "No Food Provided", FoodProvision.none),

        // Cancellation policy
        .cancellation("cancelFlexible", "Flexible Cancellation", .flexible),
        .cancellation("cancelModerate", "Moderate Cancellation", .moderate),
        .cancellation("cancelStrict",   "Strict Cancellation",   .strict),
    ]

    static func options(for category: FilterCategory) -> [FilterOption] {
        all.filter { $0.category == category }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case `default`     = "Default"
    /// Only offered once the city query has geocoded, since otherwise there's no center; see `GeoScope`.
    case nearest       = "Nearest"
    case mostEager     = "Most Eager to Host"
    case mostFlexible  = "Most Flexible Cancellation"
    case mostRooms     = "Most Rooms"
    case mostGuests    = "Most Guests"
    case mostDays      = "Most Days"
    case fewestGuests  = "Most Private"
    case mostAmenities = "Most Amenities"
    case cityAZ        = "City (A→Z)"

    var id: String { rawValue }
}

/// Whether the feed should keep pulling pages for an active search or filter. Pure
/// and `Equatable` so stopping conditions are unit-tested and the view can restart its task.
struct FeedSearchPaging: Equatable {
    var isNarrowing: Bool
    var canLoadMore: Bool
    var isLoadingMore: Bool
    var hasError: Bool
    var pagesLoaded: Int
    var maxPages: Int

    /// Unfetched pages could still hold matches; suppresses the empty state until all are checked.
    var isSearchingRemainingPages: Bool {
        isNarrowing && canLoadMore && (isLoadingMore || pagesLoaded < maxPages)
    }

    /// Stops on `hasError` too: a failed page leaves `canLoadMore` set and the loop would retry to the cap.
    var shouldFetchNextPage: Bool {
        isSearchingRemainingPages && !isLoadingMore && !hasError
    }
}

/// The visible list: the feed narrowed by filter chips, city/state query, saved-only
/// and radius, then sorted. `query` is pre-trimmed and lowercased. `scope` is the
/// geocoded query and radius; nil with no query or an unrecognised place, where the
/// radius filter and `nearest` sort no-op rather than emptying the feed over a typo.
func filterAndSort(
    _ homes: [Home],
    query: String,
    filters: Set<FilterOption>,
    savedIDs: Set<String>,
    savedOnly: Bool,
    sort: SortOption,
    scope: GeoScope? = nil
) -> [Home] {
    let result = homes.filter { home in
        filters.allSatisfy { $0.matches(home) } &&
        (query.isEmpty || home.address.city.lowercased().contains(query) || home.address.state.lowercased().contains(query)) &&
        (!savedOnly || savedIDs.contains(home.id)) &&
        (scope?.contains(home) ?? true)
    }
    switch sort {
    case .nearest:       return scope.map { nearestFirst(result, scope: $0) } ?? result
    case .mostEager:     return result.sorted { $0.hostMotivation.rank > $1.hostMotivation.rank }
    case .mostFlexible:  return result.sorted { ($0.cancellationPolicy ?? .flexible).flexibilityRank > ($1.cancellationPolicy ?? .flexible).flexibilityRank }
    case .mostDays:      return result.sorted { $0.guestPolicy.maxStayDays > $1.guestPolicy.maxStayDays }
    case .mostGuests:    return result.sorted { $0.guestPolicy.maxGuests > $1.guestPolicy.maxGuests }
    case .mostRooms:     return result.sorted { $0.sleeping.numGuestRooms > $1.sleeping.numGuestRooms }
    case .fewestGuests:  return result.sorted { $0.guestPolicy.maxGuests < $1.guestPolicy.maxGuests }
    case .mostAmenities: return result.sorted { $0.amenities.count > $1.amenities.count }
    case .cityAZ:        return result.sorted { $0.address.city < $1.address.city }
    default:             return result
    }
}

/// Closest to the search center first. Listings with no coordinate sort last, not
/// dropped. Distances are computed once per listing rather than in the comparator,
/// which falls through to the id for a stable order, as `HomeStore.feed` does.
private func nearestFirst(_ homes: [Home], scope: GeoScope) -> [Home] {
    homes
        .map { (home: $0, distance: scope.distance(to: $0) ?? .greatestFiniteMagnitude) }
        .sorted { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            return a.home.id < b.home.id
        }
        .map(\.home)
}


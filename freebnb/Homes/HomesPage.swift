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
    case cancellation = "Cancellation"
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

    // Source of truth. Declaration order drives menu order and chip order.
    static let all: [FilterOption] = [
        // Host motivation
        FilterOption(id: "notSelective", label: "Available to Host", category: .host) { $0.hostMotivation != .selective },
        FilterOption(id: "eager",     label: "Eager to Host",   category: .host) { $0.hostMotivation == .eager },
        FilterOption(id: "open",      label: "Open to Hosting", category: .host) { $0.hostMotivation == .open },
        FilterOption(id: "selective", label: "Selective",       category: .host) { $0.hostMotivation == .selective },

        // Guests & Space
        FilterOption(id: "guestRoom", label: "Guest has Private Room", category: .guestsAndSpace) { $0.sleeping.numGuestRooms > 0 },
        FilterOption(id: "sleepingBed", label: "Guest has Bed", category: .guestsAndSpace) { ($0.sleeping.sleepingCounts[.bed] ?? 0) > 0 },
        .bool("kidsAllowed", "Kids Allowed", .guestsAndSpace, \.guestPolicy.kidsAllowed),
        .bool("guestPetsAllowed", "Guest Can Bring Pets", .guestsAndSpace, \.guestPolicy.guestPetsAllowed),
        .bool("hostHasPets", "Host Has Pets", .guestsAndSpace, \.amenities.hostHasPets),

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

struct HomesPage: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore

    @State private var selectedFilters: Set<FilterOption> = []
    @State private var selectedSort: SortOption = .default
    @State private var citySearch: String = ""
    @State private var showSavedOnly: Bool = false
    @State private var showFriends: Bool = false
    @State private var showMap: Bool = false
    // Stable shuffle: we track the desired display order as an array of IDs, then
    // derive the display list from live `listings`. This means content edits to
    // existing listings always propagate immediately (computed from live data),
    // while additions/removals update the ID order.
    @State private var shuffleOrder: [String] = []
    // Cached derived lists — recomputed only when inputs change via onChange.
    @State private var shuffledListings: [Home] = []
    @State private var filteredListings: [Home] = []

    var listings: [Home]
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = false
    var error: String? = nil
    var onLoadMore: () -> Void = {}
    var onRefresh: () async -> Void = {}
    var onSelectHome: (Home) -> Void

    private func recomputeShuffled() -> [Home] {
        let byID = Dictionary(uniqueKeysWithValues: listings.map { ($0.id, $0) })
        var result = shuffleOrder.compactMap { byID[$0] }
        let seen = Set(shuffleOrder)
        result += listings.filter { !seen.contains($0.id) }
        return result
    }

    private func filterBinding(_ filter: FilterOption) -> Binding<Bool> {
        Binding(
            get: { selectedFilters.contains(filter) },
            set: { isOn in
                if isOn { selectedFilters.insert(filter) }
                else { selectedFilters.remove(filter) }
            }
        )
    }

    @ViewBuilder
    private func listingRow(_ listing: Home) -> some View {
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

    private func recomputeFiltered(from shuffled: [Home]) -> [Home] {
        let query = citySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let savedIDs = userProfileStore.currentProfile?.savedIDs ?? []
        let result = shuffled.filter { home in
            selectedFilters.allSatisfy { $0.matches(home) } &&
            (query.isEmpty || home.address.city.lowercased().contains(query) || home.address.state.lowercased().contains(query)) &&
            (!showSavedOnly || savedIDs.contains(home.id))
        }
        switch selectedSort {
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

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Search by city or state", text: $citySearch)
                    .autocorrectionDisabled()
                if !citySearch.isEmpty {
                    Button {
                        citySearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

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
                filterMenu
                sortMenu
                savedButton
                Spacer()
            }

            HStack {
                if !selectedFilters.isEmpty || selectedSort != .default || !citySearch.isEmpty || showSavedOnly {
                    Button {
                        selectedFilters.removeAll()
                        selectedSort = .default
                        citySearch = ""
                        showSavedOnly = false
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                let count = filteredListings.count
                Text("\(count)\(canLoadMore ? "+" : "") home\(count == 1 ? "" : "s")")
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
                        listingRow(listing)
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
                    emptyStateView
                }
            }
            .refreshable { await onRefresh() }
        }
        .padding(30)
        .background(.creamWhite)
        .navigationTitle("Available FreeBNBs")
        .toolbar { friendsToolbarItem; mapToolbarItem }
        .sheet(isPresented: $showFriends) { friendsSheet }
        .sheet(isPresented: $showMap) {
            ListingsMapView(listings: listings) { home in
                onSelectHome(home)
            }
        }
        .onAppear {
            if shuffleOrder.isEmpty && !listings.isEmpty {
                shuffleOrder = listings.map { $0.id }.shuffled()
            }
            let s = recomputeShuffled()
            shuffledListings = s
            filteredListings = recomputeFiltered(from: s)
        }
        .onChange(of: listings.map { $0.id }) { _, newIDs in
            let newIDSet = Set(newIDs)
            shuffleOrder = shuffleOrder.filter { newIDSet.contains($0) }
            let seen = Set(shuffleOrder)
            let added = newIDs.filter { !seen.contains($0) }.shuffled()
            shuffleOrder.append(contentsOf: added)
            let s = recomputeShuffled()
            shuffledListings = s
            filteredListings = recomputeFiltered(from: s)
        }
        .onChange(of: listings) { _, _ in
            // Listing content changed (not just IDs); refresh without reshuffling.
            let s = recomputeShuffled()
            shuffledListings = s
            filteredListings = recomputeFiltered(from: s)
        }
        .onChange(of: selectedFilters) { _, _ in
            filteredListings = recomputeFiltered(from: shuffledListings)
        }
        .onChange(of: selectedSort) { _, _ in
            filteredListings = recomputeFiltered(from: shuffledListings)
        }
        .onChange(of: citySearch) { _, _ in
            filteredListings = recomputeFiltered(from: shuffledListings)
        }
        .onChange(of: showSavedOnly) { _, _ in
            filteredListings = recomputeFiltered(from: shuffledListings)
        }
        .onChange(of: userProfileStore.currentProfile?.savedListingIDs) { _, _ in
            filteredListings = recomputeFiltered(from: shuffledListings)
        }
    }

    @ToolbarContentBuilder
    private var friendsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showFriends = true
            } label: {
                if friendStore.friendEdges.isEmpty && friendStore.pendingCount == 0 {
                    Label("Add Friends", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Color.appTeal)
                } else {
                    ZStack(alignment: .topTrailing) {
                        Label("Friends", systemImage: "person.2")
                            .font(.subheadline.weight(.medium))
                        if friendStore.pendingCount > 0 {
                            Text("\(friendStore.pendingCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
                }
            }
            .accessibilityLabel(friendStore.pendingCount > 0
                ? "Friends, \(friendStore.pendingCount) pending"
                : friendStore.friendEdges.isEmpty ? "Add Friends" : "Friends")
        }
    }

    @ToolbarContentBuilder
    private var mapToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showMap = true
            } label: {
                Image(systemName: "map")
            }
            .accessibilityLabel("Show map view")
        }
    }

    private var friendsSheet: some View {
        NavigationStack {
            FriendsPage()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showFriends = false }
                    }
                }
        }
    }

    private var emptyStateView: some View {
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
            emptyStateMessage
        }
        .padding()
    }

    private var filterMenu: some View {
        Menu {
            ForEach(FilterCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(FilterOption.options(for: category)) { filter in
                        Toggle(filter.label, isOn: filterBinding(filter))
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
        .menuActionDismissBehavior(.disabled)
    }

    private var sortMenu: some View {
        Menu {
            Button("Default") { selectedSort = .default }
            Button("Most Eager to Host") { selectedSort = .mostEager }
            Button("Most Flexible Cancellation") { selectedSort = .mostFlexible }
            Button("Most Rooms") { selectedSort = .mostRooms }
            Button("Most Guests") { selectedSort = .mostGuests }
            Button("Most Days") { selectedSort = .mostDays }
            Button("Most Private") { selectedSort = .fewestGuests }
            Button("Most Amenities") { selectedSort = .mostAmenities }
            Button("City (A→Z)") { selectedSort = .cityAZ }
        } label: {
            let label = selectedSort == .default ? "Sort" : "Sort: \(selectedSort.rawValue)"
            Label(label, systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appTeal.opacity(0.15), in: Capsule())
                .foregroundColor(Color.appTeal)
        }
        .transaction { t in t.animation = nil }
    }

    private var savedButton: some View {
        Button {
            showSavedOnly.toggle()
        } label: {
            Label("Saved", systemImage: showSavedOnly ? "bookmark.fill" : "bookmark")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(showSavedOnly ? Color.appTeal.opacity(0.3) : Color.appTeal.opacity(0.15), in: Capsule())
                .foregroundColor(Color.appTeal)
        }
    }

    @ViewBuilder
    private var emptyStateMessage: some View {
        if showSavedOnly {
            Text("You haven't saved any listings yet. Open a listing and tap \"Save listing\" to bookmark it for later.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Show all listings") { showSavedOnly = false }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appTeal.opacity(0.15), in: Capsule())
                .foregroundColor(Color.appTeal)
        } else if selectedFilters.isEmpty && citySearch.isEmpty {
            Text("FreeBNB only shows homes from people in your network. Invite a friend who hosts, or ask someone to add you.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            ShareLink(
                item: "Join me on FreeBNB — free stays with people you trust. Download the app and we can connect!",
                subject: Text("FreeBNB Invite")
            ) {
                Label("Invite a Friend", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.appTeal.opacity(0.15), in: Capsule())
                    .foregroundColor(Color.appTeal)
            }
        } else {
            Text("Try removing some filters to see more results.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear All Filters") { selectedFilters.removeAll() }
                .buttonStyle(.borderedProminent)
                .tint(Color.appTeal)
        }
    }

    // Selected filters sorted in the same order as the filter menu.
    private var sortedSelectedFilters: [FilterOption] {
        FilterOption.all.filter { selectedFilters.contains($0) }
    }

    private var filterLabel: String {
        selectedFilters.isEmpty ? "Filter" : "Filter (\(selectedFilters.count))"
    }

    private func accessibilitySummary(for listing: Home) -> String {
        let rooms = "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")"
        let guests = "\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")"
        let nights = "up to \(listing.guestPolicy.maxStayDays) night\(listing.guestPolicy.maxStayDays == 1 ? "" : "s")"
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
        .environment(UserProfileStore())
        .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
}

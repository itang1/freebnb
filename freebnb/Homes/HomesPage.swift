//
//  HomesPage.swift
//  freebnb
//
//  The list of listings with filtering and sorting; reports which home was tapped.
//

import SwiftUI

struct HomesPage: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(DeepLinkRouter.self) private var router

    @State private var selectedFilters: Set<FilterOption> = []
    @State private var selectedSort: SortOption = .default
    @State private var citySearch: String = ""
    @State private var showSavedOnly: Bool = false
    @State private var showMap: Bool = false
    /// Pages fetched for the active query, reset when it changes; bounds the exhaustion loop.
    @State private var searchPagesLoaded = 0
    /// The geocoded city query and the radius around it; nil until a query resolves.
    @State private var searchCenter: Coordinate?
    @State private var radiusMiles: Double?

    /// A pathological feed shouldn't page forever behind one keystroke.
    private static let maxSearchPages = 20

    /// CLGeocoder allows about 50 requests a minute, so each keystroke cancels
    /// the pending task and only a pause reaches it.
    private static let geocodeDebounce = Duration.milliseconds(500)

    // `listings` arrives ordered by HomeStore.feed (newest first, friends ahead);
    // the default sort keeps that order and the others reorder it.
    var listings: [Home]
    /// Viewer identity and friend set from `ContentView`'s `FeedContext`, used to
    /// explain each card. Empty for signed-out or anonymous viewers.
    var viewerID: String = ""
    var friendIDs: Set<String> = []
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = false
    var error: String? = nil
    var onLoadMore: () -> Void = {}
    var onRefresh: () async -> Void = {}
    var onSelectHome: (Home) -> Void

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
            HomeCard(
                listing: listing,
                reason: FeedSections.reason(for: listing, myID: viewerID, friendIDs: friendIDs),
                distanceMiles: geoScope?.distance(to: listing)
            )
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("\(listing.hostName) in \(listing.address.city), \(listing.address.state)")
        .accessibilityValue(accessibilitySummary(for: listing))
        .accessibilityHint("Opens listing details")
    }

    // The visible list: filter, sort and saved applied to `listings`. Computed,
    // not mirrored into @State, so it can't go stale and "Saved" updates instantly.
    private var filteredListings: [Home] {
        filterAndSort(
            listings,
            query: citySearch.trimmingCharacters(in: .whitespaces).lowercased(),
            filters: selectedFilters,
            savedIDs: userProfileStore.currentProfile?.savedIDs ?? [],
            savedOnly: showSavedOnly,
            sort: selectedSort,
            scope: geoScope
        )
    }

    /// The active search center and radius, or nil when the query hasn't geocoded.
    private var geoScope: GeoScope? {
        searchCenter.map { GeoScope(center: $0, radiusMiles: radiusMiles) }
    }

    /// Placeholders show only before the first page; afterwards, no matches is a result.
    private var showingSkeletons: Bool { isLoading && filteredListings.isEmpty }

    // Search, filters and the saved toggle narrow only the pages fetched so far,
    // so a query could show "No homes found" while its matches sat unfetched and
    // the load-more sentinel never fired. Firestore can't do substring queries,
    // so while a narrowing control is active we pull the remaining pages.
    private var isNarrowingFeed: Bool {
        !citySearch.trimmingCharacters(in: .whitespaces).isEmpty
            || !selectedFilters.isEmpty
            || showSavedOnly
    }

    /// Also the id the exhaustion loop restarts on, so the task re-runs for the next page until a `FeedSearchPaging` stop trips.
    private var paging: FeedSearchPaging {
        FeedSearchPaging(
            isNarrowing: isNarrowingFeed,
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            hasError: error != nil,
            pagesLoaded: searchPagesLoaded,
            maxPages: Self.maxSearchPages
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondaryText)
                    .accessibilityHidden(true)
                TextField("Search by city or state", text: $citySearch)
                    .autocorrectionDisabled()
                if !citySearch.isEmpty {
                    Button {
                        citySearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondaryText)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.warning)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }

            // Scrollable: the controls outgrow a small screen with the radius menu and long sort labels.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterMenu
                    sortMenu
                    if searchCenter != nil {
                        radiusMenu
                    }
                    savedButton
                }
            }

            HStack {
                if !selectedFilters.isEmpty || selectedSort != .default || !citySearch.isEmpty || showSavedOnly {
                    Button {
                        selectedFilters.removeAll()
                        selectedSort = .default
                        citySearch = ""
                        showSavedOnly = false
                        radiusMiles = nil
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondaryText)
                    }
                }

                Spacer()

                let count = filteredListings.count
                Text("\(count)\(canLoadMore ? "+" : "") home\(count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondaryText)
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
                                    .foregroundColor(.secondaryText)
                            }
                            .accessibilityLabel("Remove \(filter.label) filter")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accent.opacity(0.2))
                        .cornerRadius(20)
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    Group {
                        if showingSkeletons {
                            ForEach(0..<4, id: \.self) { _ in
                                SkeletonHomeCard()
                            }
                            .transition(.opacity)
                        } else {
                            ForEach(filteredListings) { listing in
                                listingRow(listing)
                            }
                            .transition(.opacity)

                            if canLoadMore && !filteredListings.isEmpty {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear { onLoadMore() }
                            }

                            if paging.isSearchingRemainingPages && filteredListings.isEmpty {
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text("Searching all listings…")
                                        .font(.subheadline)
                                        .foregroundColor(.secondaryText)
                                }
                                .padding(.vertical, 24)
                            } else if isLoadingMore {
                                ProgressView()
                                    .padding(.vertical, 16)
                            }

                            if !isLoading && !paging.isSearchingRemainingPages && filteredListings.isEmpty {
                                emptyStateView
                            }
                        }
                    }
                    .animation(AppAnimation.contentSwap, value: showingSkeletons)
                    // Animate on IDs so rows slide rather than pop, without re-running for unrelated field changes.
                    .animatesListChanges(on: filteredListings.map(\.id))
                }
            }
            .refreshable { await onRefresh() }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .background(.primaryBackground)
        // A new query gets a fresh page budget; the fetched pages stay in the store.
        .onChange(of: citySearch) { _, _ in searchPagesLoaded = 0 }
        .onChange(of: selectedFilters) { _, _ in searchPagesLoaded = 0 }
        .onChange(of: showSavedOnly) { _, _ in searchPagesLoaded = 0 }
        .task(id: paging) {
            guard paging.shouldFetchNextPage else { return }
            searchPagesLoaded += 1
            onLoadMore()
        }
        // Resolves the city query to a point; restarted (cancelled) on every keystroke.
        .task(id: citySearch) { await resolveSearchCenter() }
        // Losing the center would strand the radius and the nearest sort.
        .onChange(of: searchCenter) { _, center in
            guard center == nil else { return }
            radiusMiles = nil
            if selectedSort == .nearest { selectedSort = .default }
        }
        .navigationTitle("Available FreeBNBs")
        .toolbar { mapToolbarItem }
        .sheet(isPresented: $showMap) {
            ListingsMapView(listings: listings) { home in
                onSelectHome(home)
            }
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

    /// Geocodes the trimmed city query after a typing pause. A query naming nowhere
    /// leaves `searchCenter` nil, disabling the radius menu and nearest sort.
    private func resolveSearchCenter() async {
        let query = citySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchCenter = nil
            return
        }
        try? await Task.sleep(for: Self.geocodeDebounce)
        guard !Task.isCancelled else { return }
        let resolved = try? await GeocodingCache.shared.coordinate(for: query)
        // The query may have moved on; a late answer must not overwrite the new one.
        guard !Task.isCancelled else { return }
        searchCenter = resolved.map { Coordinate($0) }
    }
}

// The filter chips and empty state live in an extension to keep the struct body under lint's type-length limit.
private extension HomesPage {
    var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            EmptyStateMedallion(systemImage: "house.lodge.fill")
            Text(emptyStateTitle)
                .font(.title3)
                .fontWeight(.semibold)
            emptyStateMessage
        }
        .padding()
        // The suggestions bridge needs the friends-of-friends list, which otherwise loads only with the Friends tab.
        .task {
            if isUnfilteredEmptyFeed {
                await friendStore.loadSuggestions()
            }
        }
    }

    var filterMenu: some View {
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
                .capsuleChip()
        }
        .menuActionDismissBehavior(.disabled)
    }

    /// Only once `searchCenter` resolves; a radius with no center is meaningless.
    var radiusMenu: some View {
        Menu {
            Button(SearchRadius.label(nil)) { radiusMiles = nil }
            ForEach(SearchRadius.options, id: \.self) { miles in
                Button(SearchRadius.label(miles)) { radiusMiles = miles }
            }
        } label: {
            Label(SearchRadius.label(radiusMiles), systemImage: "location.circle")
                .capsuleChip(prominent: radiusMiles != nil)
        }
        .accessibilityLabel("Search radius, \(SearchRadius.label(radiusMiles))")
    }

    var sortMenu: some View {
        Menu {
            Button("Default") { selectedSort = .default }
            if searchCenter != nil {
                Button("Nearest") { selectedSort = .nearest }
            }
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
                .capsuleChip(prominent: selectedSort != .default)
        }
        .transaction { t in t.animation = nil }
    }

    var savedButton: some View {
        Button {
            showSavedOnly.toggle()
        } label: {
            Label("Saved", systemImage: showSavedOnly ? "bookmark.fill" : "bookmark")
                .capsuleChip(prominent: showSavedOnly)
        }
    }

    /// True when nothing narrows the feed and it's still empty: the viewer's network is the cause.
    var isUnfilteredEmptyFeed: Bool {
        !showSavedOnly && selectedFilters.isEmpty && citySearch.isEmpty
    }

    var trimmedCityQuery: String {
        citySearch.trimmingCharacters(in: .whitespaces)
    }

    /// "3 people you may know are on FreeBNB" (grammatical at one); bridges an empty feed to suggestions.
    var suggestionBridgeLabel: String {
        let count = friendStore.suggestions.count
        return count == 1
            ? "1 person you may know is on FreeBNB"
            : "\(count) people you may know are on FreeBNB"
    }

    var emptyStateTitle: String {
        if isUnfilteredEmptyFeed && friendStore.friendEdges.isEmpty {
            return "Homes come from friends"
        }
        return "No homes found"
    }

    @ViewBuilder
    var emptyStateMessage: some View {
        if showSavedOnly {
            Text("You haven't saved any listings yet. Open a listing and tap \"Save listing\" to bookmark it for later.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Button("Show all listings") { showSavedOnly = false }
                .capsuleChip()
        } else if isUnfilteredEmptyFeed && friendStore.friendEdges.isEmpty {
            // The feed is empty because the friend list is (all listings are friends-only).
            Text("Your feed shows your friends' places, and only they can see yours. Add your first friend to get started.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                router.pendingFriendsTab = true
            } label: {
                Label("Find Friends", systemImage: "person.badge.plus")
                    .capsuleChip()
            }
        } else if isUnfilteredEmptyFeed {
            Text("None of your friends have listed a place yet. Know someone with a couch or a guest room? Ask if they'd like to share it.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            ShareLink(
                item: InviteCopy.askToHost(inviterName: userProfileStore.displayName, senderID: userProfileStore.currentProfile?.id),
                subject: Text("FreeBNB Invite")
            ) {
                Label("Ask a Friend About Hosting", systemImage: "sofa")
                    .capsuleChip()
            }
            if !friendStore.suggestions.isEmpty {
                Button {
                    router.pendingFriendsTab = true
                } label: {
                    Label(suggestionBridgeLabel, systemImage: "person.2")
                        .capsuleChip()
                }
            }
        } else if !trimmedCityQuery.isEmpty {
            // A trip with nowhere to stay is the highest-intent invite moment.
            Text("No friends with a place near \"\(trimmedCityQuery)\" yet. Who would you normally text for a couch there? If they join, their place shows up here.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            ShareLink(
                item: InviteCopy.tripIntent(city: trimmedCityQuery, inviterName: userProfileStore.displayName, senderID: userProfileStore.currentProfile?.id),
                subject: Text("FreeBNB Invite")
            ) {
                Label("Invite a Friend There", systemImage: "paperplane")
                    .capsuleChip()
            }
        } else {
            Text("Try removing some filters to see more results.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Button("Clear All Filters") { selectedFilters.removeAll() }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
        }
    }

    // Selected filters in the filter menu's order.
    var sortedSelectedFilters: [FilterOption] {
        FilterOption.all.filter { selectedFilters.contains($0) }
    }

    var filterLabel: String {
        selectedFilters.isEmpty ? "Filter" : "Filter (\(selectedFilters.count))"
    }

    func accessibilitySummary(for listing: Home) -> String {
        let rooms = "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")"
        let guests = "\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")"
        let nights = "up to \(listing.guestPolicy.maxStayDays) night\(listing.guestPolicy.maxStayDays == 1 ? "" : "s")"
        return "\(rooms), \(guests), \(nights)"
    }
}

#Preview {
    HomesPage(listings: [], onSelectHome: { _ in })
        .previewEnvironment()
}

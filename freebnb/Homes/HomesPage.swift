//
//  HomesPage.swift
//  freebnb
//
//  Shows a list of Home listings. Lets the user filter them. Lets the user
//  sort them. Tells its parent which home was tapped.
//

import SwiftUI

struct HomesPage: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore

    @State private var selectedFilters: Set<FilterOption> = []
    @State private var selectedSort: SortOption = .default
    @State private var citySearch: String = ""
    @State private var showSavedOnly: Bool = false
    @State private var showFriends: Bool = false
    @State private var showMap: Bool = false
    /// Pages fetched on behalf of the active query, reset whenever the query
    /// changes. Bounds the exhaustion loop below.
    @State private var searchPagesLoaded = 0
    /// The geocoded city query, and how far from it the user will look
    /// (feature 11). Nil until a query resolves to somewhere real.
    @State private var searchCenter: Coordinate?
    @State private var radiusMiles: Double?

    /// A pathological feed shouldn't page forever behind one keystroke.
    private static let maxSearchPages = 20

    /// CLGeocoder is rate-limited to roughly 50 requests a minute, and a city
    /// name arrives one keystroke at a time. Each keystroke cancels the pending
    /// task, so only a pause in typing actually reaches the geocoder.
    private static let geocodeDebounce = Duration.milliseconds(500)

    // `listings` arrives already ordered newest-first (with friends' listings
    // grouped ahead) by HomeStore.feed, so the feed no longer shuffles it — a
    // random order buried the recency signal L3 added. The default sort preserves
    // that incoming order; the other sorts reorder it explicitly.
    var listings: [Home]
    /// Viewer identity and friend set, supplied by `ContentView` from the same
    /// `FeedContext` that ranks the feed. Used to explain each card (feature 18)
    /// and to populate the network rail (feature 10). Empty for a signed-out or
    /// anonymous viewer, which collapses both features to nothing.
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

    // Single derived source of truth for the visible list: filter + sort + saved
    // applied to the incoming `listings`. Computed rather than mirrored into
    // @State so it recomputes automatically whenever any input changes (filters,
    // sort, search, the saved-only toggle, or the user's saved-listing set) and
    // can never go stale from a missing onChange trigger. This is what makes the
    // "Saved" filter update the instant a listing is bookmarked or unbookmarked.
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

    /// The active search center and radius, or nil when the query has not
    /// geocoded (or there is no query at all).
    private var geoScope: GeoScope? {
        searchCenter.map { GeoScope(center: $0, radiusMiles: radiusMiles) }
    }

    /// Placeholders stand in only before the first page arrives. Once any listing
    /// is on screen, a filter that matches nothing is a result, not a load.
    private var showingSkeletons: Bool { isLoading && filteredListings.isEmpty }

    /// The rail's members (feature 10), drawn from the whole loaded feed rather
    /// than `filteredListings`. It is suppressed while a narrowing control is
    /// active: someone who has typed a city is answering their own question, and
    /// a rail of listings that ignore the query would be noise on top of it.
    private var networkRailListings: [Home] {
        guard !isNarrowingFeed else { return [] }
        return FeedSections.newFromYourNetwork(listings, myID: viewerID, friendIDs: friendIDs)
    }

    // Search, filters, and the saved-only toggle all narrow `listings`, which
    // holds only the pages fetched so far. So a query matching nothing on page
    // one used to render "No homes found" while its matches sat unfetched on
    // page two, and the load-more sentinel — which only appears beneath a
    // non-empty list — never fired to go get them (L3).
    //
    // Firestore can't answer a substring query, and the feed's ordering and
    // ACL gating leave no room for a prefix range. So while a
    // narrowing control is active we simply pull the remaining pages and let
    // the client-side predicate see the whole feed.
    private var isNarrowingFeed: Bool {
        !citySearch.trimmingCharacters(in: .whitespaces).isEmpty
            || !selectedFilters.isEmpty
            || showSavedOnly
    }

    /// Doubles as the id the exhaustion loop restarts on: each fetch flips
    /// `isLoadingMore` and bumps `searchPagesLoaded`, so the task re-runs and
    /// pulls the next page until one of `FeedSearchPaging`'s stops trips.
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

            // Scrollable because the controls are wider than a small screen once
            // the radius menu joins them and the sort label spells out a choice
            // as long as "Most Flexible Cancellation".
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
                        .background(Color.accent.opacity(0.2))
                        .cornerRadius(20)
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 15) {
                    let rail = networkRailListings
                    if !showingSkeletons && !rail.isEmpty {
                        NetworkRail(
                            listings: rail,
                            viewerID: viewerID,
                            friendIDs: friendIDs,
                            onSelectHome: onSelectHome
                        )
                        .padding(.bottom, 4)
                        .transition(.opacity)
                    }

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
                                        .foregroundColor(.secondary)
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
                    // Filtering, sorting, and the saved-only toggle all rewrite this
                    // list in place; animate on identity so rows slide rather than
                    // pop. Keyed on IDs, not the Homes themselves, so an unrelated
                    // field change does not re-run the transition.
                    .animatesListChanges(on: filteredListings.map(\.id))
                }
            }
            .refreshable { await onRefresh() }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(30)
        .background(.primaryBackground)
        // A new query gets a fresh page budget; the pages themselves stay in the
        // store, so this only re-arms how far the next search may reach.
        .onChange(of: citySearch) { _, _ in searchPagesLoaded = 0 }
        .onChange(of: selectedFilters) { _, _ in searchPagesLoaded = 0 }
        .onChange(of: showSavedOnly) { _, _ in searchPagesLoaded = 0 }
        .task(id: paging) {
            guard paging.shouldFetchNextPage else { return }
            searchPagesLoaded += 1
            onLoadMore()
        }
        // Resolves the city query to a point to measure from (feature 11).
        // Restarted — and so cancelled — on every keystroke.
        .task(id: citySearch) { await resolveSearchCenter() }
        // Losing the center strands both geo controls: a radius with nothing to
        // be within, and a sort that would silently stop sorting.
        .onChange(of: searchCenter) { _, center in
            guard center == nil else { return }
            radiusMiles = nil
            if selectedSort == .nearest { selectedSort = .default }
        }
        .navigationTitle("Available FreeBNBs")
        .toolbar { friendsToolbarItem; mapToolbarItem }
        .sheet(isPresented: $showFriends) { friendsSheet }
        .sheet(isPresented: $showMap) {
            ListingsMapView(listings: listings) { home in
                onSelectHome(home)
            }
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
                        .foregroundColor(Color.accent)
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

    /// Geocodes the trimmed city query after a pause in typing. A query that
    /// names nowhere leaves `searchCenter` nil, which disables the radius menu and
    /// the nearest sort rather than emptying the feed.
    private func resolveSearchCenter() async {
        let query = citySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchCenter = nil
            return
        }
        try? await Task.sleep(for: Self.geocodeDebounce)
        guard !Task.isCancelled else { return }
        let resolved = try? await GeocodingCache.shared.coordinate(for: query)
        // The query may have moved on while the geocoder was working; the task is
        // cancelled in that case, and a late answer must not overwrite the new one.
        guard !Task.isCancelled else { return }
        searchCenter = resolved.map { Coordinate($0) }
    }
}

// The filter chips and empty state live in an extension so the struct body —
// state, feed derivation, and `body` — stays within lint's type-length limit.
private extension HomesPage {
    var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "house.lodge.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accent.opacity(0.4), Color.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text(emptyStateTitle)
                .font(.title3)
                .fontWeight(.semibold)
            emptyStateMessage
        }
        .padding()
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

    /// Only rendered once `searchCenter` resolves: a radius with nothing at its
    /// center is a filter the user cannot reason about.
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

    /// True when nothing is narrowing the feed and it is still empty: the
    /// emptiness is about the viewer's network, not their query.
    var isUnfilteredEmptyFeed: Bool {
        !showSavedOnly && selectedFilters.isEmpty && citySearch.isEmpty
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
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Show all listings") { showSavedOnly = false }
                .capsuleChip()
        } else if isUnfilteredEmptyFeed && friendStore.friendEdges.isEmpty {
            // The feed is empty because the friend list is: every listing on
            // FreeBNB is friends-only, so the fix lives on the Friends page.
            Text("Your feed shows your friends' places, and only they can see yours. Add your first friend to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showFriends = true
            } label: {
                Label("Find Friends", systemImage: "person.badge.plus")
                    .capsuleChip()
            }
        } else if isUnfilteredEmptyFeed {
            Text("None of your friends have listed a home yet. Invite someone who hosts, or ask friends to list their place.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            ShareLink(
                item: "Join me on FreeBNB: free stays with people you trust. Download the app and we can connect!",
                subject: Text("FreeBNB Invite")
            ) {
                Label("Invite a Friend", systemImage: "person.badge.plus")
                    .capsuleChip()
            }
        } else {
            Text("Try removing some filters to see more results.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear All Filters") { selectedFilters.removeAll() }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
        }
    }

    // Selected filters sorted in the same order as the filter menu.
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
        .environment(UserProfileStore())
        .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
}

//
//  ContentView.swift
//  freebnb
//

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(HomeStore.self) private var homeStore
    @Environment(StayRequestStore.self) private var stayRequestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(DeepLinkRouter.self) private var router
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(CheckInKitStore.self) private var checkInKitStore
    @AppStorage(UserDefaultsKey.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(UserDefaultsKey.ageGateAccepted) private var ageGateAccepted = false
    @AppStorage(UserDefaultsKey.lastSeenWhatsNewVersion) private var lastSeenWhatsNewVersion = ""
    @State private var showOnboarding = false
    @State private var pendingHostListing = false
    @State private var showCreateListing = false
    @State private var showWhatsNew = false
    @State private var listingsPath = NavigationPath()
    @AppStorage(UserDefaultsKey.selectedTab) private var selectedTab = 0
    @State private var messagesDeepLinkUserID: String? = nil

    // The viewer identity, friend set, and block set the feed is filtered and
    // ranked against. Cheap to build; pushing it into HomeStore only recomputes
    // the feed when this value actually changes (A1).
    private var feedContext: FeedContext {
        let myID = authManager.userID
        return FeedContext(
            myID: myID,
            friendIDs: Set(friendStore.friendEdges.map { $0.otherUserID(relativeTo: myID) }),
            blockedIDs: Set(userProfileStore.currentProfile?.blockedIDs ?? [])
        )
    }

    // The loaded listings the user has saved — the set mirrored into Spotlight.
    // A saved id that isn't in the current feed can't be described, so it's
    // skipped; it re-indexes the next time it loads.
    private var savedHomesForSpotlight: [Home] {
        let saved = Set(userProfileStore.currentProfile?.savedListingIDs ?? [])
        guard !saved.isEmpty else { return [] }
        return homeStore.listings.filter { saved.contains($0.id) }
    }

    /// Cheap change key for the check-in kit sync: the guest's accepted stays and
    /// their dates. Changes when one is accepted, moved, or cancelled, and stays
    /// still when an unrelated snapshot arrives.
    private var acceptedStayKey: [String] {
        stayRequestStore.outgoingRequests
            .filter { $0.status == .accepted }
            .map { "\($0.id)-\($0.checkIn.timeIntervalSince1970)-\($0.checkOut.timeIntervalSince1970)" }
    }

    // Cheap change key for the Spotlight sync: the saved-and-loaded listing ids.
    // Re-indexes when the saved set changes or a saved listing loads in.
    private var spotlightIndexKey: [String] {
        savedHomesForSpotlight.map(\.id)
    }

    /// The listings this user co-hosts rather than owns (feature 14). A stay
    /// request names only the owner, so this is the handle the request store
    /// needs to find the ones aimed at a co-hosted home.
    private var coHostedListingIDs: [String] {
        let myID = authManager.userID
        return homeStore.managedListings
            .filter { !$0.isHostedBy(myID) }
            .map(\.id)
            .sorted()
    }

    /// Change key for the booked-range reconciler: the incoming accepted stays and
    /// their dates. Changes when the host accepts a request, a guest accepts the
    /// host's offer, or an accepted stay is cancelled — each of which should move
    /// the listing's booked dates. Steady when an unrelated snapshot arrives.
    private var incomingAcceptedStayKey: [String] {
        stayRequestStore.incomingRequests
            .filter { $0.status == .accepted }
            .map { "\($0.id)-\($0.listingID)-\($0.checkIn.timeIntervalSince1970)-\($0.checkOut.timeIntervalSince1970)" }
            .sorted()
    }

    var body: some View {
        Group {
            if !ageGateAccepted {
                AgeGateView()
            } else if authManager.isSignedIn {
                TabView(selection: $selectedTab) {
                    NavigationStack(path: $listingsPath) {
                        HomesPage(
                            listings: homeStore.visibleListings,
                            viewerID: feedContext.myID,
                            friendIDs: feedContext.friendIDs,
                            isLoading: homeStore.isLoading,
                            isLoadingMore: homeStore.isLoadingMore,
                            canLoadMore: homeStore.canLoadMore,
                            error: homeStore.error,
                            onLoadMore: { homeStore.loadMore() },
                            onRefresh: { homeStore.reload() }
                        ) { home in
                            listingsPath.append(home)
                        }
                        .navigationDestination(for: Home.self) { home in
                            HomeDetailPage(home: home)
                        }
                    }
                    .tabItem { Label("Listings", systemImage: "house") }
                    .tag(0)

                    NavigationStack {
                        StaysTab()
                    }
                    .tabItem { Label("Stays", systemImage: "suitcase") }
                    .badge(stayRequestStore.pendingStaysTabCount)
                    .tag(1)

                    // MessagesTab owns its own NavigationStack so deep links
                    // can push onto the path programmatically.
                    MessagesTab(
                        listings: homeStore.listings,
                        deepLinkUserID: $messagesDeepLinkUserID
                    )
                    .tabItem { Label("Messages", systemImage: "message") }
                    .badge(messageStore.unreadCount)
                    .tag(2)

                    NavigationStack {
                        FriendsPage()
                    }
                    .tabItem { Label("Friends", systemImage: "person.2") }
                    .badge(friendStore.pendingCount)
                    .tag(3)

                    NavigationStack {
                        ProfilePage()
                    }
                    .tabItem { Label("Profile", systemImage: "person.fill") }
                    .tag(4)
                }
                .tint(.accent)
                // Keep HomeStore's derived feed in sync with who the viewer is,
                // who they're friends with, and who they've blocked. Fires on
                // appear (initial) and whenever any of those change.
                .onChange(of: feedContext, initial: true) { _, context in
                    homeStore.updateFeedContext(
                        myID: context.myID,
                        friendIDs: context.friendIDs,
                        blockedIDs: context.blockedIDs
                    )
                    // The same friend set decides who may *see* this user's
                    // listings, and the trigger that used to maintain that is a
                    // Cloud Function this project does not deploy.
                    Task {
                        await homeStore.refreshOwnListingACLs(
                            myID: context.myID,
                            friendIDs: context.friendIDs
                        )
                    }
                }
                .sheet(isPresented: $showOnboarding, onDismiss: {
                    hasSeenOnboarding = true
                    // A brand-new user has just seen every feature in onboarding;
                    // stamp the current version so the changelog only ever
                    // auto-presents on a later *update*, never right after install.
                    lastSeenWhatsNewVersion = Bundle.main.appVersionString
                    if pendingHostListing {
                        pendingHostListing = false
                        showCreateListing = true
                    }
                }) {
                    OnboardingPage(isPresented: $showOnboarding) {
                        pendingHostListing = true
                    }
                }
                .sheet(isPresented: $showCreateListing) {
                    CreateListingPage(mode: .create)
                }
                .sheet(isPresented: $showWhatsNew, onDismiss: {
                    lastSeenWhatsNewVersion = Bundle.main.appVersionString
                }) {
                    WhatsNewSheet { showWhatsNew = false }
                }
                .onAppear {
                    // selectedTab is persisted; a stale value pointing past the last
                    // tab (from before Friends was added, or before Info was folded
                    // into Profile) would leave the tab bar with nothing selected —
                    // land on Listings instead.
                    if selectedTab > 4 { selectedTab = 0 }
                    if !hasSeenOnboarding {
                        showOnboarding = true
                    } else if lastSeenWhatsNewVersion.isEmpty {
                        // An existing user who predates this feature: catch them up
                        // silently so the changelog auto-presents on the *next*
                        // update, not this one (and isn't suppressed forever for
                        // want of a stamped version).
                        lastSeenWhatsNewVersion = Bundle.main.appVersionString
                    } else if WhatsNew.shouldPresent(
                        currentVersion: Bundle.main.appVersionString,
                        lastSeenVersion: lastSeenWhatsNewVersion
                    ) {
                        showWhatsNew = true
                    }
                }
                .onChange(of: router.pendingConversationUserID, initial: true) { _, userID in
                    guard let userID else { return }
                    selectedTab = 2
                    messagesDeepLinkUserID = userID
                    router.pendingConversationUserID = nil
                    router.didRouteSinceSignIn = true
                }
                .onChange(of: router.pendingStayEvent, initial: true) { _, pending in
                    guard pending else { return }
                    selectedTab = 1
                    router.pendingStayEvent = false
                    router.didRouteSinceSignIn = true
                }
                .onChange(of: router.pendingFriendsTab, initial: true) { _, pending in
                    guard pending else { return }
                    selectedTab = 3
                    router.pendingFriendsTab = false
                    router.didRouteSinceSignIn = true
                }
                // Write the arrival essentials to disk while there is still a
                // network to fetch them with. Driven from here rather
                // than from StayRequestStore because building a kit needs the
                // listing's address and manual, which only HomeStore can fetch.
                // Keyed on the accepted stays themselves, so a new acceptance, a
                // date change, or a cancellation each re-reconcile.
                .onChange(of: acceptedStayKey, initial: true) { _, _ in
                    Task {
                        await checkInKitStore.sync(
                            stays: stayRequestStore.outgoingRequests,
                            viewerID: authManager.userID
                        ) { listingID in
                            guard let home = homeStore.listings.first(where: { $0.id == listingID })
                            else { return nil }
                            // Both are cached after the first call, so a repeat
                            // reconcile costs nothing.
                            async let location = homeStore.location(for: listingID)
                            async let manual = homeStore.manual(for: listingID)
                            return await (home, location, manual)
                        }
                    }
                }
                // Keep the Spotlight index in step with the saved set (feature 40).
                // Fires on appear and whenever a listing is saved/unsaved or the
                // loaded feed changes what we can describe.
                .onChange(of: spotlightIndexKey, initial: true) { _, _ in
                    SpotlightIndexer.sync(savedHomes: savedHomesForSpotlight)
                }
                // A saved listing opened from Spotlight: switch to Listings and
                // push it if it's currently loaded (drop silently otherwise).
                .onChange(of: router.pendingListingID, initial: true) { _, listingID in
                    guard let listingID else { return }
                    selectedTab = 0
                    if let home = homeStore.listings.first(where: { $0.id == listingID }) {
                        listingsPath.append(home)
                    }
                    router.pendingListingID = nil
                    router.didRouteSinceSignIn = true
                }
            } else {
                NavigationStack {
                    WelcomePage()
                }
            }
        }
        // Point the request store at the listings this user co-hosts, so requests
        // aimed at a co-hosted home reach the person managing it (feature 14).
        // Driven from here for the same reason the check-in kit sync is: only
        // HomeStore knows the roster, and the alternative is a second copy of
        // that listener inside StayRequestStore. On the outer chain rather than
        // the signed-in branch's, which the type-checker already finds long.
        .onChange(of: coHostedListingIDs, initial: true) { _, listingIDs in
            stayRequestStore.setCoHostedListingIDs(listingIDs)
        }
        // Keep each hosted listing's booked dates in step with its accepted stays
        // — the client stand-in for the onStayRequestWritten trigger. Fires when
        // the host accepts a request, when a guest accepts the host's offer (the
        // path that cannot record its own booking), and on launch. Driven from
        // here because it needs both stores: the accepted stays and the roster.
        .onChange(of: incomingAcceptedStayKey, initial: true) { _, _ in
            Task {
                await homeStore.reconcileBookedRanges(
                    hostUserID: authManager.userID,
                    acceptedStays: stayRequestStore.incomingRequests
                )
            }
        }
        // Land on the Listings tab after signing in. selectedTab is persisted,
        // so without this a returning user would reopen on whatever tab they
        // last used before signing out.
        //
        // Unless a deep link is waiting, or was just acted on: someone who signed
        // in by following an invite asked for the Friends tab, and this default
        // would drop them on an empty feed instead. See `didRouteSinceSignIn`.
        .onChange(of: authManager.isSignedIn) { _, signedIn in
            guard signedIn else {
                router.didRouteSinceSignIn = false
                return
            }
            if !router.hasPendingIntent && !router.didRouteSinceSignIn {
                selectedTab = 0
            }
        }
        .offlineBanner(isOnline: networkMonitor.isOnline)
        .appliesStoredAppearance()
    }
}

#Preview {
    ContentView()
        .previewEnvironment()
}

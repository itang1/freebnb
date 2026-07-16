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
    @AppStorage(UserDefaultsKey.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(UserDefaultsKey.ageGateAccepted) private var ageGateAccepted = false
    @AppStorage(UserDefaultsKey.lastSeenWhatsNewVersion) private var lastSeenWhatsNewVersion = ""
    @State private var showOnboarding = false
    // Set when the user answers onboarding's hosting step with "List My Place".
    // The create-listing sheet can only present after the onboarding sheet has
    // fully dismissed, so the intent is parked here and consumed in onDismiss.
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

    // Cheap change key for the Spotlight sync: the saved-and-loaded listing ids.
    // Re-indexes when the saved set changes or a saved listing loads in.
    private var spotlightIndexKey: [String] {
        savedHomesForSpotlight.map(\.id)
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
                .onChange(of: router.pendingConversationUserID) { _, userID in
                    guard let userID else { return }
                    selectedTab = 2
                    messagesDeepLinkUserID = userID
                    router.pendingConversationUserID = nil
                }
                .onChange(of: router.pendingStayEvent) { _, pending in
                    guard pending else { return }
                    selectedTab = 1
                    router.pendingStayEvent = false
                }
                .onChange(of: router.pendingFriendsTab) { _, pending in
                    guard pending else { return }
                    selectedTab = 3
                    router.pendingFriendsTab = false
                }
                // Keep the Spotlight index in step with the saved set (feature 40).
                // Fires on appear and whenever a listing is saved/unsaved or the
                // loaded feed changes what we can describe.
                .onChange(of: spotlightIndexKey, initial: true) { _, _ in
                    SpotlightIndexer.sync(savedHomes: savedHomesForSpotlight)
                }
                // A saved listing opened from Spotlight: switch to Listings and
                // push it if it's currently loaded (drop silently otherwise).
                .onChange(of: router.pendingListingID) { _, listingID in
                    guard let listingID else { return }
                    selectedTab = 0
                    if let home = homeStore.listings.first(where: { $0.id == listingID }) {
                        listingsPath.append(home)
                    }
                    router.pendingListingID = nil
                }
            } else {
                NavigationStack {
                    WelcomePage()
                }
            }
        }
        // Land on the Listings tab after signing in. selectedTab is persisted,
        // so without this a returning user would reopen on whatever tab they
        // last used before signing out.
        .onChange(of: authManager.isSignedIn) { _, signedIn in
            if signedIn { selectedTab = 0 }
        }
        .offlineBanner(isOnline: networkMonitor.isOnline)
        .appliesStoredAppearance()
    }
}

#Preview {
    ContentView()
        .previewEnvironment()
}

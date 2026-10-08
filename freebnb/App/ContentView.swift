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

    // The viewer, friend set and block set the feed is built from; HomeStore recomputes only when it changes.
    private var feedContext: FeedContext {
        let myID = authManager.userID
        return FeedContext(
            myID: myID,
            friendIDs: Set(friendStore.friendEdges.map { $0.otherUserID(relativeTo: myID) }),
            blockedIDs: Set(userProfileStore.currentProfile?.blockedIDs ?? [])
        )
    }

    // Loaded listings the user has saved, mirrored into Spotlight; unloaded ids re-index when they load.
    private var savedHomesForSpotlight: [Home] {
        let saved = Set(userProfileStore.currentProfile?.savedListingIDs ?? [])
        guard !saved.isEmpty else { return [] }
        return homeStore.listings.filter { saved.contains($0.id) }
    }

    /// Change key for the check-in kit sync: the viewer plus their accepted stays
    /// and dates. Derived by `CheckInKitStore.changeKey`, where a test pins its sign-out property.
    private var acceptedStayKey: [String] {
        CheckInKitStore.changeKey(
            authResolved: authManager.hasResolvedAuthState,
            viewerID: authManager.userID,
            stays: stayRequestStore.outgoingRequests
        )
    }

    // Change key for the Spotlight sync: the saved-and-loaded listing ids.
    private var spotlightIndexKey: [String] {
        savedHomesForSpotlight.map(\.id)
    }

    /// The listings this user co-hosts; requests name only the owner, so this is how the request store finds them.
    private var coHostedListingIDs: [String] {
        let myID = authManager.userID
        return homeStore.managedListings
            .filter { !$0.isHostedBy(myID) }
            .map(\.id)
            .sorted()
    }

    /// Change key for the booked-range reconciler: incoming accepted stays and their dates.
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

                    // MessagesTab owns its NavigationStack so deep links can push programmatically.
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
                // Keeps HomeStore's derived feed in sync with the viewer, friends and blocks.
                .onChange(of: feedContext, initial: true) { _, context in
                    homeStore.updateFeedContext(
                        myID: context.myID,
                        friendIDs: context.friendIDs,
                        blockedIDs: context.blockedIDs
                    )
                    // The friend set also decides who may see this user's listings, which no Cloud Function
                    // does here.
                    Task {
                        await homeStore.refreshOwnListingACLs(
                            myID: context.myID,
                            friendIDs: context.friendIDs
                        )
                    }
                }
                .sheet(isPresented: $showOnboarding, onDismiss: {
                    hasSeenOnboarding = true
                    // Stamp the version for new users so the changelog shows only on later updates.
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
                    // selectedTab is persisted; a stale value past the last tab would leave nothing selected.
                    if selectedTab > 4 { selectedTab = 0 }
                    if !hasSeenOnboarding {
                        showOnboarding = true
                    } else if lastSeenWhatsNewVersion.isEmpty {
                        // An existing user predating this: stamp silently so the changelog shows next update.
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
                // Keeps the Spotlight index in step with the saved set and the loaded feed.
                .onChange(of: spotlightIndexKey, initial: true) { _, _ in
                    SpotlightIndexer.sync(savedHomes: savedHomesForSpotlight)
                }
                // A saved listing opened from Spotlight: switch to Listings and push it if loaded.
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
        // Points the request store at co-hosted listings so their requests reach the manager.
        // Driven from here because only HomeStore knows the roster; on the outer chain
        // because the signed-in branch already type-checks slowly.
        .onChange(of: coHostedListingIDs, initial: true) { _, listingIDs in
            stayRequestStore.setCoHostedListingIDs(listingIDs)
        }
        // Writes arrival essentials to disk while there's a network. Driven from here
        // because building a kit needs HomeStore's address and manual.
        //
        // On the outer chain deliberately: the signed-in branch is torn down on
        // sign-out, so a modifier inside it never sees the transition and the
        // sign-out cleanup of door codes would be unreachable. Gated on a resolved
        // auth state, since the uid arrives async and an empty one reads as
        // "signed out", deleting every kit for a guest cold-launching offline at the door.
        .onChange(of: acceptedStayKey, initial: true) { _, _ in
            guard authManager.hasResolvedAuthState else { return }
            Task {
                await checkInKitStore.sync(
                    stays: stayRequestStore.outgoingRequests,
                    viewerID: authManager.userID
                ) { listingID in
                    guard let home = homeStore.listings.first(where: { $0.id == listingID })
                    else { return nil }
                    // Both are cached after the first call.
                    async let location = homeStore.location(for: listingID)
                    async let manual = homeStore.manual(for: listingID)
                    return await (home, location, manual)
                }
            }
        }
        // Keeps each hosted listing's booked dates in step with its accepted stays
        // (stand-in for the onStayRequestWritten trigger). Needs both the stays and the roster.
        .onChange(of: incomingAcceptedStayKey, initial: true) { _, _ in
            Task {
                await homeStore.reconcileBookedRanges(
                    hostUserID: authManager.userID,
                    acceptedStays: stayRequestStore.incomingRequests
                )
            }
        }
        // Lands on Listings after sign-in, since selectedTab is persisted. Unless a
        // deep link is waiting or was acted on (an invite asked for Friends); see
        // `didRouteSinceSignIn`.
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

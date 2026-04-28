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
    @AppStorage(UserDefaultsKey.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(UserDefaultsKey.ageGateAccepted) private var ageGateAccepted = false
    @State private var showOnboarding = false
    @State private var listingsPath = NavigationPath()
    @AppStorage(UserDefaultsKey.selectedTab) private var selectedTab = 0
    @State private var messagesDeepLinkUserID: String? = nil

    private var visibleListings: [Home] {
        let myID = authManager.userID
        let blocked = userProfileStore.currentProfile?.blockedIDs ?? []
        let friendIDs = Set(friendStore.friendEdges.map { $0.otherUserID(relativeTo: myID) })
        let filtered = homeStore.listings.filter { home in
            guard !blocked.contains(home.hostUserID) else { return false }
            if home.visibility == .friendsOnly {
                return home.hostUserID == myID || friendIDs.contains(home.hostUserID)
            }
            return true
        }
        // Surface friends' listings first, then own listings, then everyone else.
        return filtered.sorted { a, b in
            let aIsFriend = friendIDs.contains(a.hostUserID) || a.hostUserID == myID
            let bIsFriend = friendIDs.contains(b.hostUserID) || b.hostUserID == myID
            if aIsFriend != bIsFriend { return aIsFriend }
            return false
        }
    }

    var body: some View {
        Group {
            if !ageGateAccepted {
                AgeGateView()
            } else if authManager.isSignedIn {
                TabView(selection: $selectedTab) {
                    NavigationStack(path: $listingsPath) {
                        HomesPage(
                            listings: visibleListings,
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
                        ProfilePage()
                    }
                    .tabItem { Label("Profile", systemImage: "person.fill") }
                    .tag(3)

                    NavigationStack {
                        InfoPage()
                    }
                    .tabItem { Label("Info", systemImage: "book.fill") }
                    .tag(4)
                }
                .tint(.appTeal)
                .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
                    OnboardingPage(isPresented: $showOnboarding)
                }
                .onAppear {
                    if !hasSeenOnboarding { showOnboarding = true }
                }
                .onChange(of: router.pendingConversationUserID) { _, userID in
                    guard let userID else { return }
                    selectedTab = 2
                    messagesDeepLinkUserID = userID
                    router.pendingConversationUserID = nil
                }
            } else {
                NavigationStack {
                    WelcomePage()
                }
            }
        }
        .appliesStoredAppearance()
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(HomeStore())
        .environment(MessageStore())
        .environment(UserProfileStore(repository: InMemoryUserProfileRepository()))
        .environment(StayRequestStore())
        .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
        .environment(DeepLinkRouter())
}

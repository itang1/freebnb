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
    @AppStorage(UserDefaultsKey.hasSeenOnboarding) private var hasSeenOnboarding = false
    @AppStorage(UserDefaultsKey.ageGateAccepted) private var ageGateAccepted = false
    @State private var showOnboarding = false
    @State private var listingsPath = NavigationPath()

    private var visibleListings: [Home] {
        let blocked = userProfileStore.currentProfile?.blockedIDs ?? []
        guard !blocked.isEmpty else { return homeStore.listings }
        return homeStore.listings.filter { !blocked.contains($0.hostUserID) }
    }

    var body: some View {
        Group {
            if !ageGateAccepted {
                AgeGateView()
            } else if authManager.isSignedIn {
                TabView {
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
                    .tabItem {
                        Label("Listings", systemImage: "house")
                    }

                    NavigationStack {
                        StaysTab()
                    }
                    .tabItem {
                        Label("Stays", systemImage: "suitcase")
                    }
                    .badge(stayRequestStore.pendingStaysTabCount)

                    NavigationStack {
                        MessagesTab(listings: homeStore.listings)
                    }
                    .tabItem {
                        Label("Messages", systemImage: "message")
                    }
                    .badge(messageStore.unreadCount)

                    NavigationStack {
                        ProfilePage()
                    }
                    .tabItem {
                        Label("Profile", systemImage: "person.fill")
                    }

                    NavigationStack {
                        InfoPage()
                    }
                    .tabItem {
                        Label("Info", systemImage: "book.fill")
                    }
                }
                .tint(.appTeal)
                .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
                    OnboardingPage(isPresented: $showOnboarding)
                }
                .onAppear {
                    if !hasSeenOnboarding { showOnboarding = true }
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
}

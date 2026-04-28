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
    @AppStorage(UserDefaultsKey.hasSeenOnboarding) private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var listingsPath = NavigationPath()

    var body: some View {
        Group {
            if authManager.isSignedIn {
                TabView {
                    NavigationStack(path: $listingsPath) {
                        HomesPage(
                            listings: homeStore.listings,
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
        .environment(UserProfileStore())
        .environment(StayRequestStore())
        .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
}

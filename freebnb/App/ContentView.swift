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
    @State private var inviteToConfirm: PendingInvite? = nil

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

    // Validates an incoming invite deep link and, if the inviter is a real user,
    // stages a confirmation prompt. Guests and self-invites are ignored, and an
    // unknown inviter ID is dropped silently rather than prompting.
    private func processPendingInvite() async {
        guard let invite = router.pendingInvite else { return }
        // Guests can't have friends; leave the invite pending in case they
        // upgrade to a full account before leaving this screen.
        guard authManager.authMethod != .guest else { return }
        router.pendingInvite = nil
        guard invite.inviterID != authManager.userID else { return }
        guard let profile = await userProfileStore.fetchProfileOnce(userID: invite.inviterID) else { return }
        inviteToConfirm = PendingInvite(inviterID: invite.inviterID, inviterName: profile.displayName)
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
                .tint(.accent)
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
                // Runs on appear and whenever a new invite link arrives, so an
                // invite that was opened before sign-in is still handled once the
                // signed-in UI mounts. This is the real auth-state gate that
                // replaces the old fixed sleep.
                .task(id: router.pendingInvite) {
                    await processPendingInvite()
                }
                .alert(
                    "Add friend?",
                    isPresented: Binding(
                        get: { inviteToConfirm != nil },
                        set: { if !$0 { inviteToConfirm = nil } }
                    ),
                    presenting: inviteToConfirm
                ) { invite in
                    Button("Add") {
                        let inviterID = invite.inviterID
                        Task { try? await friendStore.sendRequest(to: inviterID) }
                        inviteToConfirm = nil
                    }
                    Button("Not now", role: .cancel) { inviteToConfirm = nil }
                } message: { invite in
                    Text("Send a friend request to \(invite.inviterName ?? "this person")?")
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

//
//  MessagesTab.swift
//  freebnb
//
//  The Messages tab: the conversations list and the navigation route it pushes.
//  Split out of the former 732-line MessagingPage.swift (A2).
//

import SwiftUI

// Used by MessagesTab's NavigationStack path so deep links can push
// programmatically without touching the parent's navigation state.
struct ConversationRoute: Hashable {
    let otherUserID: String
    let otherName: String
    let listing: Home?

    static func == (lhs: ConversationRoute, rhs: ConversationRoute) -> Bool {
        lhs.otherUserID == rhs.otherUserID
    }

    func hash(into hasher: inout Hasher) { hasher.combine(otherUserID) }
}

struct MessagesTab: View {
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(StayRequestStore.self) private var requestStore

    let listings: [Home]
    /// Set by ContentView when a push notification tap should open a conversation.
    var deepLinkUserID: Binding<String?>

    @State private var path: [ConversationRoute] = []
    @State private var searchQuery = ""

    // MARK: - Helpers

    private func displayName(for userID: String) -> String {
        if let name = userProfileStore.displayName(for: userID), !name.isEmpty { return name }
        if let host = listings.first(where: { $0.hostUserID == userID })?.hostName { return host }
        return "FreeBNB User"
    }

    /// Finds the listing associated with this conversation by looking at stay
    /// requests. Used to pass listing context into the thread.
    private func listing(for otherUserID: String) -> Home? {
        let request = requestStore.outgoingRequests.first { $0.hostUserID == otherUserID }
            ?? requestStore.incomingRequests.first { $0.guestUserID == otherUserID }
        guard let listingID = request?.listingID else { return nil }
        return listings.first { $0.id == listingID }
    }

    private var visibleSummaries: [ConversationSummary] {
        let blocked = userProfileStore.currentProfile?.blockedIDs ?? []
        let all = messageStore.conversationSummaries.filter { !blocked.contains($0.otherUserID) }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { summary in
            displayName(for: summary.otherUserID).lowercased().contains(q) ||
            summary.lastMessage.text.lowercased().contains(q)
        }
    }

    /// Skeletons stand in only for the not-yet-known empty state. Once any
    /// conversation has arrived the real list is the better answer, and a search
    /// that matches nothing is a result rather than a pending load.
    private var showingSkeletons: Bool {
        messageStore.isLoadingConversations && visibleSummaries.isEmpty && searchQuery.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if showingSkeletons {
                    List(0..<6, id: \.self) { _ in
                        SkeletonConversationRow()
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.primaryBackground.ignoresSafeArea())
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Loading conversations")
                    .transition(.opacity)
                } else if visibleSummaries.isEmpty && searchQuery.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "message")
                            .foregroundStyle(Color.accent)
                    } description: {
                        Text("Open a listing and message the host to get started.")
                    }
                    .background(Color.primaryBackground.ignoresSafeArea())
                } else if visibleSummaries.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                        .background(Color.primaryBackground.ignoresSafeArea())
                } else {
                    List {
                        ForEach(visibleSummaries) { summary in
                            let name = displayName(for: summary.otherUserID)
                            let route = ConversationRoute(
                                otherUserID: summary.otherUserID,
                                otherName: name,
                                listing: listing(for: summary.otherUserID)
                            )
                            NavigationLink(value: route) {
                                ConversationRow(
                                    otherName: name,
                                    lastMessage: summary.lastMessage,
                                    currentUserID: authManager.userID,
                                    isMuted: messageStore.isMuted(summary.id),
                                    isUnread: messageStore.isUnread(summary.id, currentUserID: authManager.userID)
                                )
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.primaryBackground.ignoresSafeArea())
                    .transition(.opacity)
                    .animatesListChanges(on: visibleSummaries.map(\.id))
                }
            }
            .animation(AppAnimation.contentSwap, value: showingSkeletons)
            .navigationTitle("Messages")
            .searchable(text: $searchQuery, prompt: "Search conversations")
            .navigationDestination(for: ConversationRoute.self) { route in
                MessagingPage(
                    otherUserID: route.otherUserID,
                    otherName: route.otherName,
                    listing: route.listing
                )
            }
        }
        .onChange(of: deepLinkUserID.wrappedValue) { _, userID in
            guard let userID else { return }
            let name = displayName(for: userID)
            path.append(ConversationRoute(
                otherUserID: userID,
                otherName: name,
                listing: listing(for: userID)
            ))
            deepLinkUserID.wrappedValue = nil
        }
    }
}

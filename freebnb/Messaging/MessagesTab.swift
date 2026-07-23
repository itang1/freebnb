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

    /// Which of that person's listings a thread is about, given their outgoing
    /// requests in the store's newest-first order. Active requests win over
    /// settled ones. Pure, so the row builder and the deep-link path apply one
    /// rule rather than two copies of it that can drift.
    private static func listingID(fromTheirRequests requests: [StayRequest]) -> String? {
        let request = requests.first { $0.status.isActive } ?? requests.first
        return request?.listingID
    }

    /// Finds the listing associated with this conversation by looking at stay
    /// requests. Used to pass listing context into the thread.
    ///
    /// Only the other person's home qualifies: an incoming request points at one
    /// of this user's own listings, and attaching that would caption the thread
    /// with their own home.
    ///
    /// The row list does not call this — it uses `rowModels(for:)`, which does
    /// the same work for every row in one pass. This stays for the deep-link
    /// path, which resolves a single conversation.
    private func listing(for otherUserID: String) -> Home? {
        let theirs = requestStore.outgoingRequests.filter { $0.hostUserID == otherUserID }
        guard let listingID = Self.listingID(fromTheirRequests: theirs) else { return nil }
        return listings.first { $0.id == listingID && $0.hostUserID == otherUserID }
    }

    /// Everything one conversation row displays, resolved up front.
    private struct RowModel: Identifiable {
        let summary: ConversationSummary
        let name: String
        let listing: Home?
        let stayContext: ConversationStayContext?
        var id: String { summary.id }
    }

    /// Builds every row's content in a single pass over the stores.
    ///
    /// Each row used to resolve its own listing and stay chip, and both of those
    /// scanned the full request lists — one of them concatenating both lists
    /// first, allocating a fresh array per row. That is O(rows x requests) per
    /// render for data that changes only when a snapshot lands. Grouping once
    /// and looking up per row makes it O(rows + requests).
    private func rowModels(for summaries: [ConversationSummary]) -> [RowModel] {
        let viewerID = authManager.userID

        var staysByOther: [String: [StayRequest]] = [:]
        for stay in requestStore.incomingRequests + requestStore.outgoingRequests {
            let other = stay.hostUserID == viewerID ? stay.guestUserID : stay.hostUserID
            staysByOther[other, default: []].append(stay)
        }
        var outgoingByHost: [String: [StayRequest]] = [:]
        for stay in requestStore.outgoingRequests {
            outgoingByHost[stay.hostUserID, default: []].append(stay)
        }
        let listingsByID = Dictionary(listings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return summaries.map { summary in
            let other = summary.otherUserID
            var home: Home?
            if let listingID = Self.listingID(fromTheirRequests: outgoingByHost[other] ?? []),
               let candidate = listingsByID[listingID], candidate.hostUserID == other {
                home = candidate
            }
            return RowModel(
                summary: summary,
                name: displayName(for: other),
                listing: home,
                // The same pure derivation as before, handed the stays for this
                // pair instead of every stay; it re-filters, so the chip is
                // identical.
                stayContext: ConversationStay.context(
                    between: viewerID,
                    and: other,
                    stays: staysByOther[other] ?? []
                )
            )
        }
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

    // MARK: - Body

    var body: some View {
        // Resolved once per body pass. `visibleSummaries` filters and searches
        // the whole list on every read, and this body reads it from four places
        // (the skeleton gate, both empty checks, and the list itself), so it ran
        // four times per render before.
        let summaries = visibleSummaries
        // Skeletons stand in only for the not-yet-known empty state. Once any
        // conversation has arrived the real list is the better answer, and a
        // search that matches nothing is a result rather than a pending load.
        let showingSkeletons = messageStore.isLoadingConversations
            && summaries.isEmpty && searchQuery.isEmpty
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
                } else if summaries.isEmpty && searchQuery.isEmpty {
                    EmptyStateView(
                        title: "No conversations yet",
                        systemImage: "message",
                        message: "Open a listing and message the host to get started."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primaryBackground.ignoresSafeArea())
                } else if summaries.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                        .background(Color.primaryBackground.ignoresSafeArea())
                } else {
                    // Built here rather than above so the empty and loading
                    // states cost nothing.
                    let rows = rowModels(for: summaries)
                    List {
                        ForEach(rows) { row in
                            let route = ConversationRoute(
                                otherUserID: row.summary.otherUserID,
                                otherName: row.name,
                                listing: row.listing
                            )
                            NavigationLink(value: route) {
                                ConversationRow(
                                    otherName: row.name,
                                    otherUserID: row.summary.otherUserID,
                                    lastMessage: row.summary.lastMessage,
                                    currentUserID: authManager.userID,
                                    isMuted: messageStore.isMuted(row.id),
                                    isUnread: messageStore.isUnread(row.id, currentUserID: authManager.userID),
                                    stayContext: row.stayContext
                                )
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.primaryBackground.ignoresSafeArea())
                    .transition(.opacity)
                    .animatesListChanges(on: rows.map(\.id))
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

#Preview {
    NavigationStack {
        MessagesTab(listings: PreviewData.homes, deepLinkUserID: .constant(nil))
    }
    .previewEnvironment()
}

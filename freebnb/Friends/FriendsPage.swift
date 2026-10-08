//
//  FriendsPage.swift
//  freebnb
//

import SwiftUI

struct FriendsPage: View {
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager
    @Environment(HomeStore.self) private var homeStore
    @Environment(CircleStore.self) private var circleStore
    @Environment(DeepLinkRouter.self) private var router

    @State private var showInvite = false
    @State private var actionError: String?
    /// The person whose invite link opened the app, shown as a card with an Add
    /// button; adding is still an explicit tap, like search.
    @State private var inviter: UserProfile?

    // Search is always present rather than behind an "Add friend" sheet. A query
    // swaps the list for results; the graph changes only on an explicit "Add".
    @State private var query = ""
    @State private var searchResults: [UserProfile] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var pendingRequests: Set<String> = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var isSearchActive: Bool { !trimmedQuery.isEmpty }

    var body: some View {
        List {
            if isSearchActive {
                searchResultsContent
            } else {
                friendManagementContent
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .searchable(text: $query, prompt: "Search by name to add friends")
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .task { await friendStore.loadSuggestions() }
        // Seeds starter circles and files new friends under Default. Idempotent.
        .task(id: friendStore.friendIDs) { await circleStore.reconcile(friendIDs: friendStore.friendIDs) }
        .task(id: trimmedQuery) { await performSearch() }
        .task(id: router.pendingInviterID) { await resolveInviter() }
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInvite = true
                } label: {
                    Label("Invite", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Invite someone to FreeBNB")
            }
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsContent: some View {
        if isSearching {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        } else if let error = searchError {
            Section { InlineErrorLabel(message: error) }
        } else if !searchResults.isEmpty {
            Section("People") {
                ForEach(searchResults) { profile in
                    if profile.id != authManager.userID {
                        SearchResultRow(
                            profile: profile,
                            state: rowState(for: profile)
                        ) {
                            Task { await sendSearchRequest(to: profile) }
                        }
                    }
                }
            }
        } else {
            // An empty search is a likely stall point: the name may be spelled
            // differently or the person isn't on FreeBNB. Name both and offer the invite.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No one found for \"\(trimmedQuery)\".")
                        .font(.subheadline)
                    Text("They may have signed up under a different name, or they may not be on FreeBNB yet.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                    ShareLink(
                        item: InviteCopy.vouch(
                            inviterName: userProfileStore.displayName,
                            senderID: userProfileStore.currentProfile?.id
                        ),
                        subject: Text("FreeBNB Invite")
                    ) {
                        Label("Invite them to FreeBNB", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Friend management

    @ViewBuilder
    private var friendManagementContent: some View {
        if let error = actionError {
            Section { InlineErrorLabel(message: error) }
        }

        // Above Requests: the one thing someone arriving by invite came to do.
        if let inviter, let inviterID = inviter.id {
            Section {
                SearchResultRow(profile: inviter, state: rowState(for: inviter)) {
                    Task { await sendSearchRequest(to: inviter) }
                }
            } header: {
                Text("Your invite")
            } footer: {
                Text(rowState(for: inviter) == .friends
                     ? "You're already connected."
                     : "\(inviter.displayName) invited you to FreeBNB. Add them to see each other's places.")
            }
            .id(inviterID)
        }

        if !friendStore.pendingIncoming.isEmpty {
            Section("Requests") {
                ForEach(friendStore.pendingIncoming) { edge in
                    FriendRequestRow(edge: edge) {
                        Task { await accept(edge) }
                    } onDecline: {
                        Task { await decline(edge) }
                    }
                }
            }
        }

        if !friendStore.pendingOutgoing.isEmpty {
            Section("Sent") {
                ForEach(friendStore.pendingOutgoing) { edge in
                    PendingOutgoingRow(edge: edge) {
                        Task { await remove(edge) }
                    }
                }
            }
        }

        if !friendStore.friendEdges.isEmpty {
            // Circles sit above the list that acts on them and explain the row subtitles. Host-only.
            Section {
                NavigationLink {
                    CirclesPage()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Circles")
                            Text("Set who can book your places, and how often")
                                .font(.caption)
                                .foregroundColor(.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "person.2.circle")
                            .foregroundColor(Color.accent)
                    }
                }
            }

            let counts = homeCountsByFriend
            Section("Friends") {
                ForEach(friendStore.friendEdges) { edge in
                    let otherID = edge.otherUserID(relativeTo: authManager.userID)
                    let name = userProfileStore.displayName(for: otherID) ?? "FreeBNB User"
                    // Unfriending is only via the profile, a deliberate act rather than a stray swipe.
                    NavigationLink {
                        UserProfilePage(userID: otherID, fallbackName: name)
                    } label: {
                        FriendRow(
                            name: name,
                            userID: otherID,
                            homeCount: counts[otherID] ?? 0,
                            circleLabel: circleLabel(for: otherID)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        NavigationLink {
                            FriendCirclePage(friendID: otherID, friendName: name)
                        } label: {
                            Label("Circle", systemImage: "person.2.circle")
                        }
                        .tint(Color.accent)
                    }
                }
            }
        }

        if !friendStore.suggestions.isEmpty {
            Section {
                ForEach(friendStore.suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion) {
                        Task { await addSuggested(suggestion) }
                    }
                }
            } header: {
                Text("People you may know")
            } footer: {
                Text("Suggested from friends you have in common. You'll see each other's places only if they accept your request.")
            }
        }

        if friendStore.friendEdges.isEmpty && friendStore.pendingIncoming.isEmpty && friendStore.pendingOutgoing.isEmpty {
            Section {
                EmptyStateView(
                    title: "No friends yet",
                    systemImage: "person.2",
                    message: "Search by name above to find people, or add someone from People you may know."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// What a friend's row says: their circle and whether rules are set on them directly. Host-only.
    private func circleLabel(for friendID: String) -> String? {
        switch circleStore.resolved(for: friendID).source {
        case .override:
            let circleName = circleStore.circle(id: circleStore.membership(for: friendID)?.circleID ?? "")?.name
            return circleName.map { "\($0) · custom rules" } ?? "Custom rules"
        case .circle(_, let name):
            return name
        case .fallbackDefault:
            return circleStore.defaultCircle?.name
        case .unconfigured:
            return nil
        }
    }

    /// Visible listings each friend hosts, keyed by UID, for the "2 homes" count.
    /// Reuses `NetworkReach`'s tested derivation; cheap enough for the body.
    private var homeCountsByFriend: [String: Int] {
        let reach = NetworkReach.compute(
            homes: homeStore.visibleListings,
            myID: authManager.userID,
            friendIDs: Set(friendStore.friendIDs),
            displayName: { userProfileStore.displayName(for: $0) }
        )
        return Dictionary(uniqueKeysWithValues: reach.hosts.map { ($0.friendID, $0.homeCount) })
    }

    // MARK: - Search actions

    /// Runs the debounced name search, driven by `.task(id: trimmedQuery)` so the
    /// newest query owns the loading state and an empty one clears it and returns to the friend list.
    private func performSearch() async {
        let needle = trimmedQuery
        guard !needle.isEmpty else {
            searchResults = []
            isSearching = false
            searchError = nil
            return
        }

        isSearching = true
        searchError = nil

        // Debounce: a newer keystroke cancels this run, so only a lull reaches the network.
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return // superseded; the newer run owns the state from here
        }

        do {
            let results = try await userProfileStore.searchProfiles(query: needle)
            guard !Task.isCancelled else { return } // don't stomp a newer query's state
            searchResults = results
            searchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }

        isSearching = false
    }

    /// Resolves the pending invite link to a profile, then clears the router so the
    /// same link can resolve again. An invite naming the viewer or no known user leaves the card off.
    private func resolveInviter() async {
        guard let inviterID = router.pendingInviterID else { return }
        router.pendingInviterID = nil
        // A leftover query would swap in search results and hide the invite card; the search text persists across tab switches.
        query = ""
        guard inviterID != authManager.userID else { return }
        inviter = await userProfileStore.fetchProfileOnce(userID: inviterID)
    }

    private func rowState(for profile: UserProfile) -> SearchResultRow.State {
        guard let id = profile.id else { return .add }
        if pendingRequests.contains(id) { return .sent }
        if let edge = friendStore.existingEdge(with: id) {
            return edge.status == .accepted ? .friends : .sent
        }
        return .add
    }

    private func sendSearchRequest(to profile: UserProfile) async {
        guard let id = profile.id else { return }
        pendingRequests.insert(id)
        do {
            try await friendStore.sendRequest(to: id)
        } catch {
            pendingRequests.remove(id)
        }
    }

    // MARK: - Friend actions

    private func accept(_ edge: FriendEdge) async {
        actionError = nil
        do { try await friendStore.accept(edge) }
        catch { actionError = error.localizedDescription }
    }

    private func decline(_ edge: FriendEdge) async {
        actionError = nil
        do { try await friendStore.decline(edge) }
        catch { actionError = error.localizedDescription }
    }

    private func remove(_ edge: FriendEdge) async {
        actionError = nil
        do { try await friendStore.remove(edge) }
        catch { actionError = error.localizedDescription }
    }

    private func addSuggested(_ suggestion: FriendSuggestion) async {
        actionError = nil
        do {
            try await friendStore.sendRequest(to: suggestion.userID)
            friendStore.dismissSuggestion(suggestion.userID)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Row views

private struct FriendRow: View {
    let name: String
    let userID: String
    let homeCount: Int
    /// The friend's circle, for the host's eyes; nil before circles exist.
    let circleLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            GeneratedAvatar(seed: userID)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                if let circleLabel {
                    Text(circleLabel)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            Spacer()
            if homeCount > 0 {
                Text("\(homeCount) home\(homeCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [name, circleLabel, homeCount > 0 ? "\(homeCount) home\(homeCount == 1 ? "" : "s")" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

private struct SuggestionRow: View {
    let suggestion: FriendSuggestion
    let onAdd: () -> Void
    @State private var didAdd = false

    var body: some View {
        HStack(spacing: 12) {
            GeneratedAvatar(seed: suggestion.userID)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayName)
                    .font(.body)
                if let mutualText = suggestion.mutualText {
                    Text(mutualText)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            Spacer()
            Button {
                didAdd = true
                onAdd()
            } label: {
                Label("Add", systemImage: "person.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundColor(Color.accent)
            }
            .buttonStyle(.plain)
            .disabled(didAdd)
        }
        .padding(.vertical, 2)
    }
}

private struct FriendRequestRow: View {
    let edge: FriendEdge
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        let otherID = edge.otherUserID(relativeTo: authManager.userID)
        let name = userProfileStore.displayName(for: otherID) ?? "FreeBNB User"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                GeneratedAvatar(seed: otherID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    // Accepting is the grant: spell out what it shares.
                    Text("Accepting lets you see each other's places and request stays")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.secondaryText.opacity(0.12))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
                Button(action: onAccept) {
                    // Coral for the answer a request waits on; other actions stay teal so coral means "someone is waiting on you".
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.callToAction)
                        .foregroundColor(.onAccent)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PendingOutgoingRow: View {
    let edge: FriendEdge
    let onCancel: () -> Void
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        let otherID = edge.otherUserID(relativeTo: authManager.userID)
        let name = userProfileStore.displayName(for: otherID) ?? "FreeBNB User"
        HStack(spacing: 12) {
            GeneratedAvatar(seed: otherID)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text("Request sent")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            Button("Cancel", role: .destructive, action: onCancel)
                .font(.subheadline)
                .buttonStyle(.pressable)
                .foregroundColor(.danger)
        }
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    enum State: Equatable { case add, sent, friends }

    let profile: UserProfile
    let state: State
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Seeded by ID only, so the avatar matches the person's own profile; a document without an id can't be friended anyway.
            GeneratedAvatar(seed: profile.id ?? "")
            Text(profile.displayName)
                .font(.body)
            Spacer()
            switch state {
            case .add:
                Button(action: onAdd) {
                    Text("Add")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            case .sent:
                Text("Sent")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            case .friends:
                Label("Friends", systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundColor(Color.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Invite sheet

struct InviteSheet: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    // The message and link live in InviteCopy so every invite surface sends the same story.
    /// The sender's own ID, so the link opens on their card at the other end.
    private var senderID: String? { userProfileStore.currentProfile?.id }

    private var inviteMessage: String {
        InviteCopy.vouch(inviterName: userProfileStore.displayName, senderID: senderID)
    }

    private var inviteLink: String {
        InviteCopy.inviteURL(senderID: senderID).absoluteString
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                Image(systemName: "house.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.accent)
                    .padding(.top, 32)

                VStack(spacing: 8) {
                    Text("Vouch for a friend")
                        .font(.title2.weight(.semibold))
                    Text("FreeBNB only shows people places from their own friends, so your invite is what unlocks the app for them. Share the link; once they're in, search for each other to connect.")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                ShareLink(item: inviteMessage) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.onAccent)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(Color.accent, in: Capsule())
                }

                if let qr = QRCode.image(for: inviteLink) {
                    VStack(spacing: 8) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160, height: 160)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("QR code that opens FreeBNB")
                        Text("Or have a friend scan this with their Camera app.")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your invite link")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                    Text(inviteLink)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondaryText)
                        .padding(10)
                        .background(Color.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 24)
                }
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        FriendsPage()
            .previewEnvironment()
    }
}

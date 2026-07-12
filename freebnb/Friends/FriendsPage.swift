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

    @State private var showInvite = false
    @State private var actionError: String?

    // Finding new friends lives on the page itself: the search bar is always
    // present rather than hidden behind an "Add friend" sheet. An active query
    // swaps the friend-management list for name-search results; the graph is only
    // ever changed by an explicit tap on "Add", never automatically.
    @State private var query = ""
    @State private var searchResults: [UserProfile] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var pendingRequests: Set<String> = []
    @State private var searchTask: Task<Void, Never>?

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
        .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
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
            Section {
                Text("No people found.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Friend management

    @ViewBuilder
    private var friendManagementContent: some View {
        if let error = actionError {
            Section { InlineErrorLabel(message: error) }
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
            let counts = homeCountsByFriend
            Section("Friends") {
                ForEach(friendStore.friendEdges) { edge in
                    let otherID = edge.otherUserID(relativeTo: authManager.userID)
                    let name = userProfileStore.displayName(for: otherID) ?? "FreeBNB User"
                    NavigationLink {
                        UserProfilePage(userID: otherID, fallbackName: name)
                    } label: {
                        FriendRow(name: name, homeCount: counts[otherID] ?? 0)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await remove(edge) }
                        } label: {
                            Label("Remove", systemImage: "person.badge.minus")
                        }
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
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                        .foregroundStyle(Color.accent)
                } description: {
                    Text("Search by name above to find people, or add someone from People you may know.")
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    /// How many visible listings each friend hosts, keyed by friend UID, so the
    /// Friends list can show a "2 homes" count beside each name. Reuses
    /// `NetworkReach`'s tested derivation (own listings excluded, only verified
    /// friends counted). Pure and cheap, so deriving it in the body is fine.
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

    /// Debounces the name search: each keystroke cancels the pending fetch, so
    /// only a pause in typing reaches `searchProfiles`. An empty query clears the
    /// results and drops back to the friend-management list.
    private func scheduleSearch(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            searchError = nil
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        searchError = nil
        do {
            searchResults = try await userProfileStore.searchProfiles(query: query)
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
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
    let homeCount: Int

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: name)
            Text(name)
                .font(.body)
            Spacer()
            if homeCount > 0 {
                Text("\(homeCount) home\(homeCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            homeCount > 0
                ? "\(name), \(homeCount) home\(homeCount == 1 ? "" : "s")"
                : name
        )
    }
}

private struct SuggestionRow: View {
    let suggestion: FriendSuggestion
    let onAdd: () -> Void
    @State private var didAdd = false

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: suggestion.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayName)
                    .font(.body)
                if let mutualText = suggestion.mutualText {
                    Text(mutualText)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                InitialsAvatar(name: name, tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    // Accepting is the grant: spell out what it shares.
                    Text("Accepting lets you see each other's places and request stays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
                Button(action: onAccept) {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.accent)
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
            InitialsAvatar(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text("Request sent")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel", role: .destructive, action: onCancel)
                .font(.subheadline)
                .buttonStyle(.pressable)
                .foregroundColor(.red)
        }
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    enum State { case add, sent, friends }

    let profile: UserProfile
    let state: State
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: profile.displayName)
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
                    .foregroundColor(.secondary)
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

    private var inviterName: String {
        userProfileStore.displayName ?? "A friend"
    }

    /// A plain link that just opens the app. It carries no identity and takes no
    /// action: opening it never creates a friend connection. Once both people are
    /// on FreeBNB they add each other in-app, through search and an accepted
    /// request, so there is nothing here to spoof or act on.
    private var inviteURL: URL {
        var components = URLComponents()
        components.scheme = "freebnb"
        components.host = "invite"
        // Force-unwrap is safe: compile-time constant URL.
        return components.url ?? URL(string: "freebnb://invite")!
    }

    private var inviteMessage: String {
        "\(inviterName) invited you to FreeBNB — a free home-sharing app for people who trust each other. Install the app, then search for me to send a friend request: \(inviteURL.absoluteString)"
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
                    Text("Invite to FreeBNB")
                        .font(.title2.weight(.semibold))
                    Text("Share the link below so your friend can install the app. Once they're on FreeBNB, search for each other to send a friend request.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                ShareLink(item: inviteMessage) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(Color.accent, in: Capsule())
                }

                if let qr = QRCode.image(for: inviteURL.absoluteString) {
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
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your invite link")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(inviteURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

//
//  FriendsPage.swift
//  freebnb
//

import SwiftUI

struct FriendsPage: View {
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager

    @State private var showAddFriend = false
    @State private var actionError: String?

    var body: some View {
        List {
            if let error = actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
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
                Section("Friends") {
                    ForEach(friendStore.friendEdges) { edge in
                        let otherID = edge.otherUserID(relativeTo: authManager.userID)
                        FriendRow(
                            name: userProfileStore.displayName(for: otherID) ?? "FreeBNB User",
                            userID: otherID
                        )
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

            if friendStore.friendEdges.isEmpty && friendStore.pendingIncoming.isEmpty && friendStore.pendingOutgoing.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No friends yet", systemImage: "person.2")
                            .foregroundStyle(Color.appTeal)
                    } description: {
                        Text("Add friends to see their listings and let them request to stay with you.")
                    } actions: {
                        Button("Add a Friend") { showAddFriend = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appTeal)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddFriend = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("Add friend")
            }
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet()
        }
    }

    // MARK: - Actions

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
}

// MARK: - Row views

private struct FriendRow: View {
    let name: String
    let userID: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appTeal.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(Color.appTeal)
                )
            Text(name)
                .font(.body)
        }
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
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundColor(.orange)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    Text("Wants to connect")
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
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.appTeal)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
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
            Circle()
                .fill(Color.appTeal.opacity(0.10))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(Color.appTeal)
                )
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
                .buttonStyle(.plain)
                .foregroundColor(.red)
        }
    }
}

// MARK: - Add Friend Sheet

struct AddFriendSheet: View {
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var pendingRequests: Set<String> = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search by name", text: $query)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if let error = searchError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                } else if !results.isEmpty {
                    Section("People") {
                        ForEach(results) { profile in
                            if profile.id != authManager.userID {
                                SearchResultRow(
                                    profile: profile,
                                    state: rowState(for: profile)
                                ) {
                                    Task { await sendRequest(to: profile) }
                                }
                            }
                        }
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && !isSearching {
                    Section {
                        Text("No people found.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    results = []
                    isSearching = false
                    return
                }
                isSearching = true
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await search(trimmed)
                }
            }
        }
    }

    private func rowState(for profile: UserProfile) -> SearchResultRow.State {
        guard let id = profile.id else { return .add }
        if pendingRequests.contains(id) { return .sent }
        if let edge = friendStore.existingEdge(with: id) {
            return edge.status == .accepted ? .friends : .sent
        }
        return .add
    }

    private func search(_ query: String) async {
        isSearching = true
        searchError = nil
        do {
            results = try await userProfileStore.searchProfiles(query: query)
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func sendRequest(to profile: UserProfile) async {
        guard let id = profile.id else { return }
        pendingRequests.insert(id)
        do {
            try await friendStore.sendRequest(to: id)
        } catch {
            pendingRequests.remove(id)
        }
    }
}

private struct SearchResultRow: View {
    enum State { case add, sent, friends }

    let profile: UserProfile
    let state: State
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appTeal.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(profile.displayName.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(Color.appTeal)
                )
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
                        .background(Color.appTeal)
                        .foregroundColor(.white)
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
                    .foregroundColor(Color.appTeal)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        FriendsPage()
            .environment(FriendStore())
            .environment(UserProfileStore())
            .environment(AuthManager())
    }
}

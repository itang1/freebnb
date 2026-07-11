//
//  CoHostManagerView.swift
//  freebnb
//
//  Host-only sheet for managing a listing's co-hosts (feature 14): add a friend,
//  or remove someone already on the roster. Only the host reaches this — the
//  dashboard gates it on `isHostedBy` — and `firestore.rules` refuses a roster
//  write from anyone else regardless, so this sheet is convenience over a
//  boundary, not the boundary itself.
//

import SwiftUI

struct CoHostManagerView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var busyUserID: String?
    @State private var errorMessage: String?

    /// The live listing, so the roster reflects an add or remove without waiting
    /// for the sheet to be reopened. Falls back to the passed snapshot before the
    /// managed-listings snapshot has arrived.
    private var current: Home {
        homeStore.managedListings.first { $0.id == listing.id } ?? listing
    }

    private var hostUserID: String { authManager.userID }

    /// Accepted friends who are not already co-hosts. A co-host must be a friend
    /// (the rules enforce it), so the picker never offers anyone else.
    private var addableFriends: [String] {
        let roster = Set(current.coHosts)
        return friendStore.friendIDs.filter { !roster.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Co-hosts can edit this listing's details and see its address and house manual. They can't change who can see it, manage co-hosts, delete it, or respond to stay requests — those stay with you.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                currentRoster
                addSection

                if let errorMessage {
                    Section { InlineErrorLabel(message: errorMessage) }
                }
            }
            .navigationTitle("Co-hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var currentRoster: some View {
        if current.coHosts.isEmpty {
            Section("Current co-hosts") {
                Text("No co-hosts yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Current co-hosts") {
                ForEach(current.coHosts, id: \.self) { userID in
                    HStack {
                        Text(name(for: userID))
                            .font(.subheadline)
                        Spacer()
                        if busyUserID == userID {
                            ProgressView()
                        } else {
                            Button("Remove", role: .destructive) {
                                Task { await remove(userID) }
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var addSection: some View {
        if current.coHosts.count >= Home.maxCoHosts {
            Section {
                Text("This listing has the maximum of \(Home.maxCoHosts) co-hosts.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else if addableFriends.isEmpty {
            Section("Add a co-host") {
                Text(friendStore.friendIDs.isEmpty
                     ? "Add a friend first — a co-host has to be someone you're connected with."
                     : "All of your friends already co-host this listing.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Add a co-host") {
                ForEach(addableFriends, id: \.self) { userID in
                    HStack {
                        Text(name(for: userID))
                            .font(.subheadline)
                        Spacer()
                        if busyUserID == userID {
                            ProgressView()
                        } else {
                            Button("Add") {
                                Task { await add(userID) }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Color.accent)
                        }
                    }
                }
            }
        }
    }

    private func name(for userID: String) -> String {
        userProfileStore.displayName(for: userID) ?? "FreeBNB User"
    }

    private func add(_ userID: String) async {
        busyUserID = userID
        errorMessage = nil
        defer { busyUserID = nil }
        do {
            try await homeStore.addCoHost(userID, to: current, hostUserID: hostUserID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ userID: String) async {
        busyUserID = userID
        errorMessage = nil
        defer { busyUserID = nil }
        do {
            try await homeStore.removeCoHost(userID, from: current, hostUserID: hostUserID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

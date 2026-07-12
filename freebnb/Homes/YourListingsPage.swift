//
//  YourListingsPage.swift
//  freebnb
//

import SwiftUI

/// One sheet, three modes. SwiftUI resolves stacked `.sheet` modifiers on a
/// single view unreliably, so create, edit, and duplicate share one presentation
/// keyed by this value rather than getting a modifier each.
private struct ListingSheet: Identifiable, Hashable {
    let mode: ListingFormMode

    var id: String {
        switch mode {
        case .create:                return "create"
        case .edit(let home):        return "edit-\(home.id)"
        case .duplicate(let home):   return "duplicate-\(home.id)"
        }
    }
}

struct YourListingsPage: View {
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @State private var sheet: ListingSheet?
    @State private var deleteTarget: Home? = nil
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var myID: String { authManager.userID }

    /// Listings this user hosts, and separately the ones a friend made them a
    /// co-host of (feature 14). Split because the two rows differ in what they
    /// let you do: only the host may delete, duplicate, or manage the roster.
    private var hostedListings: [Home] {
        homeStore.managedListings.filter { $0.isHostedBy(myID) }
    }

    private var coHostedListings: [Home] {
        homeStore.managedListings.filter { !$0.isHostedBy(myID) }
    }

    var body: some View {
        Group {
            if homeStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primaryBackground.ignoresSafeArea())
            } else if homeStore.managedListings.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .navigationTitle("Your Listings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = ListingSheet(mode: .create)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create listing")
            }
        }
        .sheet(item: $sheet) { sheet in
            CreateListingPage(mode: sheet.mode)
        }
        .confirmationDialog(
            "Delete this listing?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await delete(target) }
            }
        } message: {
            Text("This removes the listing for everyone. Existing conversations are not affected.")
        }
        .overlay {
            if isDeleting {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        List {
            if let errorMessage {
                Section { InlineErrorLabel(message: errorMessage) }
            }

            // A plain list until there is something to co-host; the header would
            // otherwise label a section that has no counterpart.
            if coHostedListings.isEmpty {
                ForEach(hostedListings) { listing in
                    hostedRow(listing)
                }
            } else {
                Section("Listings you host") {
                    ForEach(hostedListings) { listing in
                        hostedRow(listing)
                    }
                }
                Section("Listings you co-host") {
                    ForEach(coHostedListings) { listing in
                        coHostedRow(listing)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    /// A listing this user hosts: the full set of actions.
    private func hostedRow(_ listing: Home) -> some View {
        NavigationLink {
            ListingDashboardPage(listing: listing)
        } label: {
            ListingRow(listing: listing, street: homeStore.listingLocations[listing.id]?.street)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = listing
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                sheet = ListingSheet(mode: .edit(listing))
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accent)
        }
        // A host with a guest room and a couch at the same address shouldn't
        // retype it (feature 13). Also reachable by long press, since a swipe
        // hides its actions until you go looking.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                sheet = ListingSheet(mode: .duplicate(listing))
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.accent)
        }
        .contextMenu {
            Button {
                sheet = ListingSheet(mode: .edit(listing))
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                sheet = ListingSheet(mode: .duplicate(listing))
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                deleteTarget = listing
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// A listing this user co-hosts: they may open and edit it, but deleting,
    /// duplicating, and roster changes belong to the host alone (feature 14).
    /// Duplicate is withheld too — it copies someone else's home to a new listing
    /// the co-host would own, which is not what "co-host" invites.
    private func coHostedRow(_ listing: Home) -> some View {
        NavigationLink {
            ListingDashboardPage(listing: listing)
        } label: {
            ListingRow(listing: listing, street: homeStore.listingLocations[listing.id]?.street, isCoHost: true)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                sheet = ListingSheet(mode: .edit(listing))
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accent)
        }
        .contextMenu {
            Button {
                sheet = ListingSheet(mode: .edit(listing))
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No listings yet", systemImage: "house")
                .foregroundStyle(Color.accent)
        } description: {
            Text("Create your first listing so friends can find a place to stay.")
        } actions: {
            Button("Create a Listing") {
                sheet = ListingSheet(mode: .create)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    // MARK: - Delete

    private func delete(_ home: Home) async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await homeStore.delete(home)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct ListingRow: View {
    let listing: Home
    /// From the private location doc; nil until it loads.
    let street: String?
    /// Marks a listing the viewer co-hosts rather than owns (feature 14).
    var isCoHost: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(listing.address.city), \(listing.address.state)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    if isCoHost {
                        Text("Co-host")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Color.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accent.opacity(0.15), in: Capsule())
                    }
                }
                Text(street ?? listing.address.zip)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label("\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")", systemImage: "person.fill")
                    Text("·")
                    Label("\(listing.guestPolicy.maxStayDays) night\(listing.guestPolicy.maxStayDays == 1 ? "" : "s") max", systemImage: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .labelStyle(.titleAndIcon)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        YourListingsPage()
            .previewEnvironment()
    }
}

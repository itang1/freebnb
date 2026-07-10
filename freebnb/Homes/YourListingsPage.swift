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
    @State private var sheet: ListingSheet?
    @State private var deleteTarget: Home? = nil
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var yourListings: [Home] {
        homeStore.ownListings
    }

    var body: some View {
        Group {
            if homeStore.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primaryBackground.ignoresSafeArea())
            } else if yourListings.isEmpty {
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
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }

            ForEach(yourListings) { listing in
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
                // A host with a guest room and a couch at the same address
                // shouldn't retype it (feature 13). Also reachable by long press,
                // since a swipe hides its actions until you go looking.
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
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
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
    /// From the host's own private location doc; nil until it loads.
    let street: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.headline)
                    .foregroundColor(.primary)
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
            .environment(HomeStore())
            .environment(StayRequestStore())
    }
}

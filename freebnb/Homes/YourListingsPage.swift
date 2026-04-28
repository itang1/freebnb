//
//  YourListingsPage.swift
//  freebnb
//

import SwiftUI

struct YourListingsPage: View {
    @Environment(HomeStore.self) private var homeStore
    @State private var showCreate = false
    @State private var editing: Home? = nil
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
                    .background(Color.creamWhite.ignoresSafeArea())
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
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create listing")
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateListingPage()
        }
        .sheet(item: $editing) { home in
            CreateListingPage(editing: home)
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
                    ListingRow(listing: listing)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = listing
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        editing = listing
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.appTeal)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamWhite.ignoresSafeArea())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No listings yet", systemImage: "house")
                .foregroundStyle(Color.appTeal)
        } description: {
            Text("Create your first listing so friends can find a place to stay.")
        } actions: {
            Button("Create a Listing") {
                showCreate = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appTeal)
        }
        .background(Color.creamWhite.ignoresSafeArea())
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(listing.address.street)
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

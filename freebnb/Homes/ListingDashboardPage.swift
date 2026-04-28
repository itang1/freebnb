//
//  ListingDashboardPage.swift
//  freebnb
//
//  Per-listing host dashboard: pending and upcoming stay requests, related
//  guest conversations, and quick access to listing edit.
//

import SwiftUI

struct ListingDashboardPage: View {
    let listing: Home

    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore

    @State private var respondingTo: StayRequest?
    @State private var actionError: String?
    @State private var showEdit = false
    @State private var showPast = false

    // MARK: - Derived data

    private var listingRequests: [StayRequest] {
        requestStore.incomingRequests
            .filter { $0.listingID == listing.id }
            .sortedByDate()
    }

    private var pendingRequests:  [StayRequest] { listingRequests.filter { $0.status == .pending  } }
    private var acceptedRequests: [StayRequest] { listingRequests.filter { $0.status == .accepted } }
    private var pastRequests:     [StayRequest] { listingRequests.filter { !$0.status.isActive   } }

    private var guestIDs: Set<String> { Set(listingRequests.map { $0.guestUserID }) }

    /// Conversations with any guest who has sent a request for this listing.
    private var relatedConversations: [ConversationSummary] {
        messageStore.conversationSummaries.filter { guestIDs.contains($0.otherUserID) }
    }

    private var hasContent: Bool {
        !listingRequests.isEmpty || !relatedConversations.isEmpty
    }

    // MARK: - Body

    var body: some View {
        List {
            listingSummarySection

            if !hasContent {
                Section {
                    Text("No requests yet. Share your listing so guests can find it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }

            if !pendingRequests.isEmpty {
                Section("Needs your response") {
                    ForEach(pendingRequests) { req in
                        IncomingRequestRow(
                            request: req,
                            guestName: guestName(for: req),
                            showActions: true,
                            onAccept:  { respondingTo = req },
                            onDecline: { Task { await decline(req) } }
                        )
                    }
                }
            }

            if !acceptedRequests.isEmpty {
                Section("Upcoming stays") {
                    ForEach(acceptedRequests) { req in
                        IncomingRequestRow(request: req, guestName: guestName(for: req))
                    }
                }
            }

            if !relatedConversations.isEmpty {
                Section("Guest conversations") {
                    ForEach(relatedConversations) { summary in
                        let name = guestDisplayName(for: summary.otherUserID)
                        NavigationLink {
                            MessagingPage(
                                otherUserID: summary.otherUserID,
                                otherName: name,
                                listing: listing
                            )
                        } label: {
                            conversationRow(name: name, summary: summary)
                        }
                    }
                }
            }

            if !pastRequests.isEmpty {
                Section {
                    Button {
                        withAnimation { showPast.toggle() }
                    } label: {
                        Label(
                            showPast ? "Hide past requests" : "Show past requests",
                            systemImage: showPast ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
                if showPast {
                    Section("Past requests") {
                        ForEach(pastRequests) { req in
                            IncomingRequestRow(request: req, guestName: guestName(for: req))
                        }
                    }
                }
            }

            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle("\(listing.address.city) Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit Listing") { showEdit = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.appTeal)
            }
        }
        .sheet(isPresented: $showEdit) {
            CreateListingPage(editing: listing)
        }
        .sheet(item: $respondingTo) { req in
            AcceptSheet(request: req) { hostNote in
                await accept(req, hostNote: hostNote)
            }
        }
    }

    // MARK: - Listing summary

    private var listingSummarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: listing.hostMotivation.iconName)
                        .font(.caption2)
                    Text(listing.hostMotivation.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(listing.hostMotivation.tintColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(listing.hostMotivation.tintColor.opacity(0.12))
                .clipShape(Capsule())

                Text(listing.address.street)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 14) {
                    Label(
                        "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")",
                        systemImage: "bed.double"
                    )
                    Label(
                        "\(listing.sleeping.maxGuests) guest\(listing.sleeping.maxGuests == 1 ? "" : "s")",
                        systemImage: "person.fill"
                    )
                    Label(
                        "\(listing.sleeping.maxStayDays)d max",
                        systemImage: "calendar"
                    )
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .labelStyle(.titleAndIcon)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Conversation row

    private func conversationRow(name: String, summary: ConversationSummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.appTeal.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text(String(name.prefix(1)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.appTeal)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline).fontWeight(.semibold)
                HStack(spacing: 2) {
                    if summary.lastMessage.senderUserID == authManager.userID {
                        Text("You: ").font(.caption).foregroundColor(.secondary)
                    }
                    Text(summary.lastMessage.text)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(summary.lastMessage.timestamp ?? Date(), style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func guestName(for request: StayRequest) -> String {
        userProfileStore.displayName(for: request.guestUserID) ?? "FreeBNB User"
    }

    private func guestDisplayName(for userID: String) -> String {
        if let name = userProfileStore.displayName(for: userID), !name.isEmpty { return name }
        return listingRequests.first(where: { $0.guestUserID == userID })
            .map { _ in "FreeBNB User" } ?? "FreeBNB User"
    }

    private func dateRangeText(_ request: StayRequest) -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))"
    }

    // MARK: - Actions

    private func accept(_ request: StayRequest, hostNote: String?) async {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            var text = "✅ Stay accepted · \(dateRangeText(request))"
            if let note = hostNote, !note.isEmpty { text += "\n\(note)" }
            messageStore.send(
                text: text,
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
            respondingTo = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func decline(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.decline(request)
            messageStore.send(
                text: "Stay request declined · \(dateRangeText(request))",
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }
}

#Preview {
    let home = Home(
        hostUserID: "preview-host",
        hostName: "Michaela",
        address: Address(street: "40 Cummings Rd", city: "Brighton", state: "MA", zip: "02135"),
        contactPreference: .inApp,
        hostMotivation: .eager,
        sleeping: Sleeping(
            numGuestRooms: 1, maxGuests: 2, maxStayDays: 14,
            arrangements: ["bed": 1],
            kidsAllowed: true, guestPetsAllowed: false, hostHasPets: false
        ),
        amenities: Amenities(
            hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
            hasMicrowave: true, hasTV: true, hasWifi: true,
            hasPrivateGuestBathroom: false, parkingDetails: "",
            hasInUnitLaundry: true, hasCoinLaundryNearby: false,
            providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: true,
            foodProvision: .some
        )
    )
    NavigationStack {
        ListingDashboardPage(listing: home)
            .environment(StayRequestStore())
            .environment(MessageStore())
            .environment(AuthManager())
            .environment(UserProfileStore())
    }
}

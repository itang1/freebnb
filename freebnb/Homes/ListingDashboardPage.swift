//
//  ListingDashboardPage.swift
//  freebnb
//
//  Per-listing host dashboard: pending and upcoming stay requests, related
//  guest conversations, and quick access to listing edit.
//

import SwiftUI

struct ListingDashboardPage: View {
    // The snapshot the caller navigated with. `listing` below prefers the live
    // copy from the store so a co-host add/remove is reflected immediately.
    private let passedListing: Home

    init(listing: Home) {
        self.passedListing = listing
    }

    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore

    @State private var respondingTo: StayRequest?
    @State private var actionError: String?
    @State private var showEdit = false
    @State private var showAvailability = false
    @State private var showCoHosts = false
    @State private var showOffer = false
    @State private var showPast = false

    // MARK: - Derived data

    /// The live listing from the store, so a roster change reflects here without
    /// reopening the dashboard. Falls back to the snapshot the caller passed.
    private var listing: Home {
        homeStore.managedListings.first { $0.id == passedListing.id } ?? passedListing
    }

    private var isHost: Bool { listing.isHostedBy(authManager.userID) }

    private var listingRequests: [StayRequest] {
        requestStore.incomingRequests
            .filter { $0.listingID == listing.id }
            .sortedByDate()
    }

    private var pendingRequests:  [StayRequest] { listingRequests.filter { $0.status == .pending  } }
    private var acceptedRequests: [StayRequest] { listingRequests.filter { $0.status == .accepted } }
    private var pastRequests:     [StayRequest] { listingRequests.filter { !$0.status.isActive   } }
    /// Offers this host has sent that the friend hasn't answered (feature 43).
    private var sentOffers:       [StayRequest] { listingRequests.filter { $0.status == .offered  } }

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

            // Above co-hosts and offers: blocking dates is the routine upkeep a
            // host comes back to do, where the others are occasional.
            availabilitySection

            if isHost {
                coHostSection
            }

            // The one thing a host can start (feature 43). Above the request
            // sections on purpose: this page is otherwise entirely a list of
            // things other people did, which is exactly why a host with an empty
            // week had no reason to open the app.
            if isHost {
                Section {
                    Button {
                        showOffer = true
                    } label: {
                        Label("Offer your place to a friend", systemImage: "gift")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            if !hasContent {
                Section {
                    Text("No requests yet. Friends who can see this listing can ask to stay, or you can offer it to someone.")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                        .padding(.vertical, 4)
                }
            }

            if !sentOffers.isEmpty {
                Section("Offers you've sent") {
                    ForEach(sentOffers) { req in
                        IncomingRequestRow(request: req, guestName: guestName(for: req))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await withdraw(req) }
                                } label: {
                                    Label("Withdraw", systemImage: "arrow.uturn.backward")
                                }
                            }
                    }
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
                        .foregroundColor(.secondaryText)
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
                Section { InlineErrorLabel(message: actionError) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .task(id: actionError) {
            guard actionError != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            actionError = nil
        }
        .navigationTitle("\(listing.address.city) Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Availability") { showAvailability = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.accent)
            }
            // The roster is the host's alone (feature 14); a co-host manages the
            // listing but does not decide who else does.
            if isHost {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Co-hosts") { showCoHosts = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color.accent)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit Listing") { showEdit = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.accent)
            }
        }
        .sheet(isPresented: $showEdit) {
            CreateListingPage(mode: .edit(listing))
        }
        .sheet(isPresented: $showAvailability) {
            AvailabilityEditorView(listing: listing)
        }
        .sheet(isPresented: $showCoHosts) {
            CoHostManagerView(listing: listing)
        }
        .sheet(isPresented: $showOffer) {
            OfferStaySheet(listing: listing)
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
                    Text(listing.hostMotivation.homeText)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(listing.hostMotivation.tintColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(listing.hostMotivation.tintColor.opacity(0.12))
                .clipShape(Capsule())

                // Prefetched for the host's own listings by HomeStore; the zip is
                // the honest fallback while it loads.
                Text(homeStore.listingLocations[listing.id]?.street ?? listing.address.zip)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)

                HStack(spacing: 14) {
                    Label(
                        "\(listing.sleeping.numGuestRooms) room\(listing.sleeping.numGuestRooms == 1 ? "" : "s")",
                        systemImage: "bed.double"
                    )
                    Label(
                        "\(listing.guestPolicy.maxGuests) guest\(listing.guestPolicy.maxGuests == 1 ? "" : "s")",
                        systemImage: "person.fill"
                    )
                    Label(
                        "\(listing.guestPolicy.maxStayDays)d max",
                        systemImage: "calendar"
                    )
                }
                .font(.caption)
                .foregroundColor(.secondaryText)
                .labelStyle(.titleAndIcon)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Availability

    /// The blocked calendar, as a row on the page rather than only as a toolbar
    /// button.
    ///
    /// The editor was reachable the whole time, but only from `.secondaryAction`,
    /// which iOS folds into the "..." overflow menu — so the one control a host
    /// needs most was the one control with no presence on the page. It keeps its
    /// toolbar entry; this adds the visible route, and states the current position
    /// so a host can see whether anything is blocked without opening anything.
    private var availabilitySection: some View {
        Section("Availability") {
            Button {
                showAvailability = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .frame(width: 28)
                        .foregroundColor(Color.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blocked dates")
                            .foregroundColor(.primary)
                        Text(availabilitySummary)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondaryText.opacity(0.5))
                }
            }
        }
    }

    /// Counts upcoming blocked days, not ranges: "2 periods" means nothing to
    /// someone deciding whether they have room for a guest next week, and a range
    /// that started last month would inflate it either way.
    private var availabilitySummary: String {
        let blockedDays = AvailabilityCalendar.blockedDays(
            in: AvailabilityCalendar.upcoming(listing.unavailableRanges)
        )
        guard !blockedDays.isEmpty else {
            return "Nothing blocked. Tap to mark dates you can't host."
        }
        return "\(blockedDays.count) upcoming day\(blockedDays.count == 1 ? "" : "s") blocked or booked"
    }

    // MARK: - Co-hosts (feature 14)

    @ViewBuilder
    private var coHostSection: some View {
        Section("Co-hosts") {
            if listing.coHosts.isEmpty {
                Button {
                    showCoHosts = true
                } label: {
                    Label("Add a co-host", systemImage: "person.badge.plus")
                        .font(.subheadline)
                        .foregroundColor(Color.accent)
                }
            } else {
                ForEach(listing.coHosts, id: \.self) { userID in
                    HStack(spacing: 10) {
                        GeneratedAvatar(seed: userID, size: 28)
                        Text(userProfileStore.displayName(for: userID) ?? "FreeBNB User")
                            .font(.subheadline)
                    }
                }
                Button {
                    showCoHosts = true
                } label: {
                    Label("Manage co-hosts", systemImage: "person.2.badge.gearshape")
                        .font(.subheadline)
                        .foregroundColor(Color.accent)
                }
            }
        }
    }

    // MARK: - Conversation row

    private func conversationRow(name: String, summary: ConversationSummary) -> some View {
        HStack(spacing: 12) {
            GeneratedAvatar(seed: summary.otherUserID, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline).fontWeight(.semibold)
                HStack(spacing: 2) {
                    if summary.lastMessage.senderUserID == authManager.userID {
                        Text("You: ").font(.caption).foregroundColor(.secondaryText)
                    }
                    Text(summary.lastMessage.text)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(summary.lastMessage.timestamp ?? Date(), style: .time)
                .font(.caption2)
                .foregroundColor(.secondaryText)
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

    /// Returns nil on success, or the failure message for `AcceptSheet` to show.
    /// The sheet dismisses itself once this returns nil.
    private func accept(_ request: StayRequest, hostNote: String?) async -> String? {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            let note = (hostNote?.isEmpty ?? true) ? nil : hostNote
            messageStore.sendStayEvent(
                StayEvent(kind: .accepted, dateRange: dateRangeText(request), note: note),
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func decline(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.decline(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .declined, dateRange: dateRangeText(request)),
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Takes back an offer the friend hasn't answered (feature 43). Posts the
    /// `cancelled` event, not `declined`: the friend never said no, and a thread
    /// that claimed they did would be a small lie told about them.
    private func withdraw(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.withdrawOffer(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .cancelled, dateRange: dateRangeText(request)),
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
        address: Address(city: "Brighton", state: "MA", zip: "02135"),
        contactPreference: .inApp,
        hostMotivation: .eager,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 14, kidsAllowed: true, guestPetsAllowed: false),
        amenities: Amenities(
            hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
            hasMicrowave: true, hasTV: true, hasWifi: true,
            hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
            hasInUnitLaundry: true, hasCoinLaundryNearby: false,
            providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: true,
            foodProvision: .some
        )
    )
    NavigationStack {
        ListingDashboardPage(listing: home)
            .previewEnvironment()
    }
}

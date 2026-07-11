//
//  StaysTab.swift
//  freebnb
//

import SwiftUI

// Root of the Stays tab. Shows the signed-in user's outgoing stay requests
// (as a traveler) and incoming requests (as a host) in one unified view.
struct StaysTab: View {
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @Environment(ReviewStore.self) private var reviewStore
    @State private var respondingTo: StayRequest?
    @State private var reviewing: ReviewTarget?
    @State private var thanking: StayRequest?
    @State private var sharingStay: StayRequest?
    @State private var modifying: StayRequest?
    @State private var completing: StayRequest?
    @State private var actionError: String?
    @State private var selectedTab: StaysTabSelection = .trips
    @State private var showPast = false

    enum StaysTabSelection { case trips, listings }

    /// A stay plus the role the signed-in user reviews it in. Carried together so
    /// the sheet never has to re-derive who is reviewing whom.
    struct ReviewTarget: Identifiable {
        let stay: StayRequest
        let role: ReviewRole
        let subjectName: String
        var id: String { stay.id }
    }

    // Outgoing (guest / traveler)
    private var pendingOut:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .pending  } }
    private var acceptedOut: [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .accepted } }
    private var pastOut:     [StayRequest] { requestStore.outgoingRequests.filter { !$0.status.isActive   } }

    // Incoming (host)
    private var pendingIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending  } }
    private var acceptedIn: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }
    private var pastIn:     [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive   } }

    // The trip timeline splits accepted stays into the one under way right now
    // and the ones still ahead (feature 21), so a stay you're in the middle of
    // rises to the top instead of sitting in a flat "confirmed" list.
    private var inProgressOut: [StayRequest] { acceptedOut.filter { $0.isUnderway() } }
    private var upcomingOut:   [StayRequest] { acceptedOut.filter { !$0.isUnderway() } }
    private var inProgressIn:  [StayRequest] { acceptedIn.filter { $0.isUnderway() } }
    private var upcomingIn:    [StayRequest] { acceptedIn.filter { !$0.isUnderway() } }

    /// Finished stays this user hasn't reviewed yet (features 1 and 4). Empty
    /// until `ReviewStore` knows what they've already written, so nobody is asked
    /// twice for a review they already left.
    private var awaitingReview: [StayRequest] {
        requestStore.completedStays.filter { reviewStore.needsReview(stayRequestID: $0.id) }
    }

    private var hasActive: Bool {
        !pendingOut.isEmpty || !acceptedOut.isEmpty || !pendingIn.isEmpty || !acceptedIn.isEmpty
    }
    private var hasPast: Bool { !pastOut.isEmpty || !pastIn.isEmpty }
    private var hasAny: Bool { hasActive || hasPast }

    var body: some View {
        Group {
            if selectedTab == .listings {
                YourListingsPage()
            } else {
                tripsView
            }
        }
        .navigationTitle("Stays")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
                    Text("Trips").tag(StaysTabSelection.trips)
                    Text("Listings").tag(StaysTabSelection.listings)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .sheet(item: $respondingTo) { req in
            AcceptSheet(request: req) { hostNote in
                await accept(req, hostNote: hostNote)
            }
        }
        .sheet(item: $reviewing) { target in
            WriteReviewSheet(stay: target.stay, role: target.role, subjectName: target.subjectName)
                .environment(reviewStore)
                .environment(authManager)
        }
        .sheet(item: $thanking) { req in
            ThankYouSheet(hostName: req.listingHostName) { note in
                await sendThanks(req, note: note)
            }
        }
        .sheet(item: $modifying) { req in
            ModifyStaySheet(request: req, listing: listing(for: req)) { checkIn, checkOut in
                await modify(req, checkIn: checkIn, checkOut: checkOut)
            }
        }
        .sheet(item: $sharingStay) { stay in
            SafetyCheckInSheet(
                stay: stay,
                location: homeStore.listingLocations[stay.listingID],
                manual: homeStore.listingManuals[stay.listingID]
            )
            .environment(userProfileStore)
        }
        .confirmationDialog(
            "Mark this stay complete?",
            isPresented: Binding(get: { completing != nil }, set: { if !$0 { completing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mark complete") {
                if let stay = completing { Task { await markComplete(stay) } }
            }
        } message: {
            Text("This closes the stay out and lets you both leave a review. It can't be undone.")
        }
    }

    // MARK: - Trips view

    @ViewBuilder
    private var tripsView: some View {
        if let error = requestStore.listenerError {
            listenerErrorState(error)
        } else if !hasAny {
            emptyState
        } else {
            staysList
        }
    }

    private func listenerErrorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load stays", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } description: {
            Text(error)
                .font(.caption)
            Button("Retry") { requestStore.reload() }
                .font(.subheadline.weight(.medium))
                .foregroundColor(Color.accent)
                .padding(.top, 8)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No trips yet", systemImage: "suitcase")
                .foregroundStyle(Color.accent)
        } description: {
            Text("Open a listing, message the host, and request to stay. Your trips appear here.")
        }
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    private var staysList: some View {
        List {
            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            reviewSection
            travelerSections
            hostSections
            pastSection
        }
        .refreshable { requestStore.reload() }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .task(id: actionError) {
            guard actionError != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            actionError = nil
        }
    }

    /// First on the page: a stay is freshest the day it ends, and an unreviewed
    /// stay is the one thing here that both parties are waiting on each other for.
    @ViewBuilder
    private var reviewSection: some View {
        if !awaitingReview.isEmpty {
            Section("Needs your review") {
                ForEach(awaitingReview, id: \.id) { req in
                    ReviewPromptRow(
                        request: req,
                        subjectName: subjectName(for: req),
                        onReview: { startReview(req) },
                        // Guests thank the host first (feature 24); the note is
                        // optional and the flow leads into the same review. Hosts
                        // just review.
                        onThank: req.guestUserID == authManager.userID ? { thanking = req } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var travelerSections: some View {
        if !pendingOut.isEmpty {
            Section("Waiting to hear back") {
                ForEach(pendingOut, id: \.id) { req in
                    outgoingRow(
                        req,
                        onCancel: { Task { await cancel(req) } },
                        onModify: { modifying = req }
                    )
                }
            }
        }
        if !inProgressOut.isEmpty {
            Section("Happening now") {
                ForEach(inProgressOut, id: \.id) { req in
                    outgoingRow(
                        req,
                        onShare: { sharingStay = req },
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil
                    )
                }
            }
        }
        if !upcomingOut.isEmpty {
            Section("Upcoming trips") {
                ForEach(upcomingOut, id: \.id) { req in
                    outgoingRow(
                        req,
                        onShare: { sharingStay = req },
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var hostSections: some View {
        if !pendingIn.isEmpty {
            Section("Needs your response") {
                ForEach(pendingIn, id: \.id) { req in
                    incomingRow(
                        req,
                        showActions: true,
                        onAccept:  { respondingTo = req },
                        onDecline: { Task { await decline(req) } }
                    )
                }
            }
        }
        if !inProgressIn.isEmpty {
            Section("Hosting now") {
                ForEach(inProgressIn, id: \.id) { req in
                    incomingRow(
                        req,
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil
                    )
                }
            }
        }
        if !upcomingIn.isEmpty {
            Section("Upcoming hosting") {
                ForEach(upcomingIn, id: \.id) { req in
                    incomingRow(
                        req,
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var pastSection: some View {
        if hasPast {
            Section {
                Button {
                    withAnimation { showPast.toggle() }
                } label: {
                    Label(showPast ? "Hide past stays" : "Show past stays",
                          systemImage: showPast ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            if showPast {
                if !pastOut.isEmpty {
                    Section("Past trips") {
                        ForEach(pastOut, id: \.id) { req in outgoingRow(req) }
                    }
                }
                if !pastIn.isEmpty {
                    Section("Past hosting") {
                        ForEach(pastIn, id: \.id) { req in incomingRow(req) }
                    }
                }
            }
        }
    }
}

// Actions, row builders, and lookups live in a same-file extension rather than
// in the struct body: extensions do not count toward SwiftLint's type_body_length,
// and `private` is file-scoped, so they still see the view's state.
extension StaysTab {
    // MARK: - Actions

    private func cancel(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.cancel(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .cancelled, dateRange: request.dateRangeText),
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Change the dates on a pending request, then let the host know in chat with
    /// the same structured event the other lifecycle actions send (feature 23).
    private func modify(_ request: StayRequest, checkIn: Date, checkOut: Date) async {
        actionError = nil
        do {
            try await requestStore.modifyDates(request, checkIn: checkIn, checkOut: checkOut)
            let nights = max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
            let f = AppDateFormatters.shortDay
            let range = "\(f.string(from: checkIn)) – \(f.string(from: checkOut)) · \(nights) night\(nights == 1 ? "" : "s")"
            messageStore.sendStayEvent(
                StayEvent(kind: .modified, dateRange: range),
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
            )
            modifying = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func accept(_ request: StayRequest, hostNote: String?) async {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            let note = (hostNote?.isEmpty ?? true) ? nil : hostNote
            messageStore.sendStayEvent(
                StayEvent(kind: .accepted, dateRange: request.dateRangeText, note: note),
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
            messageStore.sendStayEvent(
                StayEvent(kind: .declined, dateRange: request.dateRangeText),
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func markComplete(_ request: StayRequest) async {
        actionError = nil
        completing = nil
        do {
            try await requestStore.markCompleted(request)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func startReview(_ request: StayRequest) {
        guard let role = request.reviewRole(for: authManager.userID) else { return }
        reviewing = ReviewTarget(stay: request, role: role, subjectName: subjectName(for: request))
    }

    /// Sends the optional thank-you note to the host, then hands off to the review
    /// prompt (feature 24). The brief wait lets the thank-you sheet finish
    /// dismissing before the review sheet is presented in its place.
    private func sendThanks(_ request: StayRequest, note: String?) async {
        if let note, !note.isEmpty {
            messageStore.send(
                text: note,
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
            )
        }
        thanking = nil
        try? await Task.sleep(for: .milliseconds(350))
        startReview(request)
    }

    private func guestName(for request: StayRequest) -> String {
        userProfileStore.displayName(for: request.guestUserID) ?? "FreeBNB User"
    }

    /// The other party's name, seen from the signed-in user. A guest reviews the
    /// host by their denormalized listing name; a host reviews the guest by their
    /// profile name.
    private func subjectName(for request: StayRequest) -> String {
        request.hostUserID == authManager.userID
            ? guestName(for: request)
            : request.listingHostName
    }

    // MARK: - Row builders

    /// Wraps an OutgoingRequestRow in a NavigationLink if the listing is cached.
    @ViewBuilder
    private func outgoingRow(
        _ request: StayRequest,
        onCancel: (() -> Void)? = nil,
        onModify: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) -> some View {
        if let home = listing(for: request) {
            NavigationLink { HomeDetailPage(home: home) } label: {
                OutgoingRequestRow(request: request, onCancel: onCancel, onModify: onModify, onShare: onShare, onComplete: onComplete)
            }
        } else {
            OutgoingRequestRow(request: request, onCancel: onCancel, onModify: onModify, onShare: onShare, onComplete: onComplete)
        }
    }

    /// Wraps an IncomingRequestRow in a NavigationLink if the listing is cached.
    /// Rows with inline Accept/Decline actions are never wrapped — full-width
    /// buttons would cover the entire tap area and prevent navigation.
    @ViewBuilder
    private func incomingRow(
        _ request: StayRequest,
        showActions: Bool = false,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) -> some View {
        let home = listing(for: request)
        // Show the street address when the host has more than one listing so the
        // guest's request can be traced to the right property. This row is only
        // ever rendered for the host, whose own addresses HomeStore prefetches.
        let multiListing = homeStore.listings.filter {
            $0.hostUserID == authManager.userID
        }.count > 1
        let row = IncomingRequestRow(
            request: request,
            guestName: guestName(for: request),
            listingAddress: multiListing ? home.flatMap { homeStore.listingLocations[$0.id]?.street } : nil,
            showActions: showActions,
            onAccept: onAccept,
            onDecline: onDecline,
            onComplete: onComplete
        )
        if !showActions, let home {
            NavigationLink { HomeDetailPage(home: home) } label: { row }
        } else {
            row
        }
    }

    // MARK: - Helpers

    /// Looks up the full Home object for a request from the cached listings.
    private func listing(for request: StayRequest) -> Home? {
        homeStore.listings.first { $0.id == request.listingID }
    }
}

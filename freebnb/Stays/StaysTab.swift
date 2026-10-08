//
//  StaysTab.swift
//  freebnb
//

import SwiftUI

// Root of the Stays tab: outgoing requests (as traveler) and incoming ones (as host).
struct StaysTab: View {
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @Environment(ReviewStore.self) private var reviewStore
    @Environment(FriendNoteStore.self) private var noteStore
    @Environment(GuestNoteStore.self) private var guestNoteStore
    @Environment(DeepLinkRouter.self) private var router
    @State private var respondingTo: StayRequest?
    @State private var reviewing: ReviewTarget?
    @State private var notingStay: FriendNoteComposition?
    @State private var notingTrip: GuestNoteComposition?
    @State private var thanking: StayRequest?
    @State private var sharingStay: StayRequest?
    @State private var modifying: StayRequest?
    @State private var completing: StayRequest?
    // An accepted stay about to be called off by the guest; asks first, unlike a pending cancel.
    // An accepted stay about to be called off by the guest; asks first, unlike a pending cancel.
    @State private var cancelling: StayRequest?
    // A host cancelling goes through `hostCancelling`, which tells the guest and offers a note.
    @State private var hostCancelling: StayRequest?
    @State private var actionError: String?
    @State private var selectedTab: StaysTabSelection = .trips
    @State private var showPastTrips = false
    @State private var showPastHosting = false

    enum StaysTabSelection { case trips, listings }

    /// A stay plus the role the signed-in user reviews it in.
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
    /// Offers a friend has made this user, which they owe an answer to; shown at the top.
    private var offeredOut:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .offered  } }

    // Incoming (host)
    private var pendingIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending  } }
    private var acceptedIn: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }
    private var pastIn:     [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive   } }
    /// Offers this user has made that a friend hasn't answered yet.
    private var offeredIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .offered  } }

    // The trip timeline splits accepted stays into the one under way and those ahead.
    private var inProgressOut: [StayRequest] { acceptedOut.filter { $0.isUnderway() } }
    private var upcomingOut:   [StayRequest] { acceptedOut.filter { !$0.isUnderway() } }
    private var inProgressIn:  [StayRequest] { acceptedIn.filter { $0.isUnderway() } }
    private var upcomingIn:    [StayRequest] { acceptedIn.filter { !$0.isUnderway() } }

    /// The one stay live enough to headline: an accepted stay with a real
    /// `StayPhase`, soonest check-in first. Same selection as the Live Activity.
    private var liveStay: (stay: StayRequest, phase: StayPhase)? {
        (requestStore.incomingRequests + requestStore.outgoingRequests)
            .filter { $0.status == .accepted }
            .compactMap { stay -> (StayRequest, StayPhase)? in
                guard let phase = StayPhase.current(checkIn: stay.checkIn, checkOut: stay.checkOut) else { return nil }
                return (stay, phase)
            }
            .min { $0.0.checkIn < $1.0.checkIn }
            .map { (stay: $0.0, phase: $0.1) }
    }

    /// Finished stays not yet reviewed; empty until `ReviewStore` knows what's been written.
    private var awaitingReview: [StayRequest] {
        requestStore.completedStays.filter { reviewStore.needsReview(stayRequestID: $0.id) }
    }

    // Gates the My Trips empty state (traveler side only); a host's requests live under My Listings.
    private var hasTripsContent: Bool {
        !pendingOut.isEmpty || !acceptedOut.isEmpty || !pastOut.isEmpty
    }

    var body: some View {
        // Resolved once per body pass; `awaitingReview` re-derives `completedStays` on each read.
        let awaiting = awaitingReview
        let reviewsAsGuest = awaiting.filter { $0.guestUserID == authManager.userID }
        let reviewsAsHost = awaiting.filter { $0.hostUserID == authManager.userID }
        let pendingInCount = pendingIn.count
        VStack(spacing: 0) {
            // Big filled pills rather than the system segmented control, which people
            // didn't notice switching between two very different screens.
            StaysModeSwitcher(
                selection: $selectedTab,
                tripsBadge: reviewsAsGuest.count,
                listingsBadge: pendingInCount + reviewsAsHost.count
            )

            // Pinned above both panes: a live stay is worth seeing before choosing one.
            if let live = liveStay {
                HappeningNowBanner(
                    stay: live.stay,
                    isHost: live.stay.hostUserID == authManager.userID,
                    phase: live.phase,
                    onTap: { openConversation(for: live.stay) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if selectedTab == .listings {
                    // Requests against your properties surface above the properties list.
                    YourListingsPage(title: "My Listings") {
                        listingsRequestSections(awaitingReview: reviewsAsHost)
                    }
                } else {
                    tripsView(awaitingReview: reviewsAsGuest)
                }
            }
        }
        .navigationTitle(selectedTab == .listings ? "My Listings" : "My Trips")
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(item: $notingStay) { composition in
            FriendNoteComposerSheet(
                composition: composition,
                friendName: noteSubjectName(for: composition)
            )
            .environment(noteStore)
        }
        .sheet(item: $notingTrip) { composition in
            GuestNoteComposerSheet(
                composition: composition,
                subjectName: tripNoteSubjectName(for: composition)
            )
            .environment(guestNoteStore)
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
        .confirmationDialog(
            "Cancel this stay?",
            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
            titleVisibility: .visible
        ) {
            Button("Cancel stay", role: .destructive) {
                if let stay = cancelling { Task { await cancel(stay) } }
            }
            Button("Keep stay", role: .cancel) { cancelling = nil }
        } message: {
            Text("This calls the stay off for both of you. The other person sees the change in your conversation.")
        }
        .sheet(item: $hostCancelling) { stay in
            HostCancelStaySheet(
                request: stay,
                guestName: subjectName(for: stay),
                onConfirm: { note in await hostCancel(stay, note: note) }
            )
        }
    }

    // MARK: - Trips view

    @ViewBuilder
    private func tripsView(awaitingReview: [StayRequest]) -> some View {
        if let error = requestStore.listenerError {
            listenerErrorState(error)
        } else if requestStore.isLoadingIncoming && !hasTripsContent {
            // The listener clears the lists on an account switch and refills them a round
            // trip later; "No trips yet" in that gap would be wrong.
            loadingState
        } else if !hasTripsContent {
            emptyState
        } else {
            staysList(awaitingReview: awaitingReview)
        }
    }

    private var loadingState: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primaryBackground.ignoresSafeArea())
            .accessibilityLabel("Loading stays")
    }

    private func listenerErrorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load stays", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.danger)
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
        EmptyStateView(
            title: "No trips yet",
            systemImage: "suitcase",
            message: "Open a listing, message the host, and request to stay. Your trips appear here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primaryBackground.ignoresSafeArea())
    }

    private func staysList(awaitingReview: [StayRequest]) -> some View {
        List {
            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.danger)
                }
            }
            reviewSection(awaitingReview)
            tripNoteSection
            travelerSections
            pastTripsSection
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

    /// First on the page: an unreviewed stay is something both parties wait on.
    /// Called once per pane with its role-filtered stays.
    @ViewBuilder
    private func reviewSection(_ items: [StayRequest]) -> some View {
        if !items.isEmpty {
            Section("Needs your review") {
                ForEach(items, id: \.id) { req in
                    ReviewPromptRow(
                        request: req,
                        subjectName: subjectName(for: req),
                        onReview: { startReview(req) },
                        // Guests thank the host first (optional note), then review. Hosts just review.
                        onThank: req.guestUserID == authManager.userID ? { thanking = req } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var travelerSections: some View {
        // Above "Waiting to hear back": this is the one thing others are waiting on them for.
        if !offeredOut.isEmpty {
            Section("A friend offered you a place") {
                ForEach(offeredOut, id: \.id) { req in
                    outgoingRow(
                        req,
                        onAccept:  { Task { await acceptOffer(req) } },
                        onDecline: { Task { await declineOffer(req) } }
                    )
                }
            }
        }
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
                        // A confirmed trip can be called off, with a confirmation since it affects the host.
                        onCancel: { cancelling = req },
                        onShare: { sharingStay = req },
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var hostSections: some View {
        if !offeredIn.isEmpty {
            Section("Offers you've sent") {
                ForEach(offeredIn, id: \.id) { req in
                    incomingRow(req)
                }
            }
        }
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
                        onComplete: req.canBeMarkedComplete() ? { completing = req } : nil,
                        // Firestore rules admit accepted → cancelled from the host's side; it routes
                        // through the sheet that tells the guest and offers a way back.
                        onCancel: { hostCancelling = req }
                    )
                }
            }
        }
    }

    private func pastToggleRow(isShown: Binding<Bool>, label: String) -> some View {
        Section {
            Button {
                withAnimation { isShown.wrappedValue.toggle() }
            } label: {
                Label(isShown.wrappedValue ? "Hide \(label)" : "Show \(label)",
                      systemImage: isShown.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var pastTripsSection: some View {
        if !pastOut.isEmpty {
            pastToggleRow(isShown: $showPastTrips, label: "past trips")
            if showPastTrips {
                Section("Past trips") {
                    ForEach(pastOut, id: \.id) { req in outgoingRow(req) }
                }
            }
        }
    }

    @ViewBuilder
    private var pastHostingSection: some View {
        if !pastIn.isEmpty {
            pastToggleRow(isShown: $showPastHosting, label: "past hosting")
            if showPastHosting {
                Section("Past hosting") {
                    ForEach(pastIn, id: \.id) { req in incomingRow(req) }
                }
            }
        }
    }

    // MARK: - My Listings

    /// Requests against your properties: reviews owed, live hosting sections and
    /// past hosting, injected above the properties list in `YourListingsPage`.
    @ViewBuilder
    private func listingsRequestSections(awaitingReview: [StayRequest]) -> some View {
        reviewSection(awaitingReview)
        noteSection
        hostSections
        pastHostingSection
    }

    /// Stays this host finished and hasn't been asked about yet. Host side only.
    /// Below "Needs your review" and above everything else; unlike a review,
    /// nobody is waiting on it. The window and "already asked" rule live in the
    /// tested `FriendNotePrompt`.
    private var completedStaysToNoteAbout: [StayRequest] {
        requestStore.completedStays.filter { stay in
            FriendNotePrompt.shouldOffer(
                stay,
                hostID: authManager.userID,
                isSettled: !noteStore.shouldPrompt(forStayRequestID: stay.id)
            )
        }
    }

    /// The optional add-a-note moment; this only decides which stays it covers.
    private var noteSection: some View {
        NotePromptSection(stays: completedStaysToNoteAbout, composing: $notingStay)
    }

    // MARK: - My Trips: the guest's own post-trip note

    /// Trips this guest finished and hasn't been asked about yet; the traveler-side
    /// mirror of `completedStaysToNoteAbout`. Rules live in the tested `GuestNotePrompt`.
    private var completedTripsToNoteAbout: [StayRequest] {
        requestStore.completedStays.filter { stay in
            GuestNotePrompt.shouldOffer(
                stay,
                guestID: authManager.userID,
                isSettled: !guestNoteStore.shouldPrompt(forStayRequestID: stay.id)
            )
        }
    }

    /// The optional add-a-note moment on the traveler's side; ordered like the host prompt.
    private var tripNoteSection: some View {
        GuestNotePromptSection(stays: completedTripsToNoteAbout, composing: $notingTrip)
    }
}

// Actions, row builders and lookups live in an extension to stay under SwiftLint's
// type_body_length; `private` is file-scoped so they still see the view's state.
extension StaysTab {
    // MARK: - Actions

    /// Cancels a request or accepted stay from either side; the chat event goes to the other party.
    private func cancel(_ request: StayRequest) async {
        actionError = nil
        cancelling = nil
        do {
            try await requestStore.cancel(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .cancelled, dateRange: request.dateRangeText),
                senderUserID: authManager.userID,
                recipientUserID: request.otherParty(from: authManager.userID)
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// A host calls off a confirmed stay. Sends `hostCancelled` (not `cancelled`)
    /// so the guest's card offers a way back, with the host's optional note.
    /// Returns nil on success or the message for the sheet to show.
    private func hostCancel(_ request: StayRequest, note: String?) async -> String? {
        do {
            try await requestStore.cancel(request)
            messageStore.sendStayEvent(
                StayEvent(
                    kind: .hostCancelled,
                    dateRange: request.dateRangeText,
                    note: note,
                    listingID: request.listingID
                ),
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Changes a pending request's dates, then tells the host in chat.
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
            // A booking or notice window can land under the open sheet; map the
            // rejection to the neutral "no longer available" so it never names the cause.
            actionError = StayRequestError.guestFacingMessage(for: error)
        }
    }

    /// Returns nil on success, or the failure message for `AcceptSheet`.
    private func accept(_ request: StayRequest, hostNote: String?) async -> String? {
        actionError = nil
        do {
            try await requestStore.accept(request, hostNote: hostNote)
            let note = (hostNote?.isEmpty ?? true) ? nil : hostNote
            messageStore.sendStayEvent(
                StayEvent(kind: .accepted, dateRange: request.dateRangeText, note: note),
                senderUserID: authManager.userID,
                recipientUserID: request.guestUserID
            )
            return nil
        } catch {
            // A guest's accept can be invalidated under the open sheet; map it to the
            // neutral "no longer available". A host's accept keeps the raw description.
            let viewerIsGuest = request.role(of: authManager.userID) == .guest
            return viewerIsGuest
                ? StayRequestError.guestFacingMessage(for: error)
                : error.localizedDescription
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

    /// The guest says yes to a host's offer. Goes through the same callable as a
    /// host's accept, since only the server can see competing stays.
    private func acceptOffer(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.accept(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .accepted, dateRange: request.dateRangeText),
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func declineOffer(_ request: StayRequest) async {
        actionError = nil
        do {
            try await requestStore.declineOffer(request)
            messageStore.sendStayEvent(
                StayEvent(kind: .declined, dateRange: request.dateRangeText),
                senderUserID: authManager.userID,
                recipientUserID: request.hostUserID
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

    /// Sends the optional thank-you note, then hands off to the review prompt
    /// after a brief wait so the thank-you sheet finishes dismissing.
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

    /// Who a note composed here is about: always a guest of the host's.
    private func noteSubjectName(for composition: FriendNoteComposition) -> String {
        switch composition {
        case .new(let friendID, _):
            return userProfileStore.displayName(for: friendID) ?? "FreeBNB User"
        case .editing(let note):
            return userProfileStore.displayName(for: note.subjectUserID) ?? "FreeBNB User"
        }
    }

    /// What a trip note is about: always a listing the guest stayed at, labelled
    /// from the cache or else the trip's denormalized label.
    private func tripNoteSubjectName(for composition: GuestNoteComposition) -> String {
        switch composition {
        case .new(_, let subjectID, let stayRequestID):
            if let home = homeStore.listings.first(where: { $0.id == subjectID }) {
                return home.displayTitle
            }
            // Not in the guest's cached set (it's the host's); use the label the stay snapshotted.
            if let stayRequestID,
               let stay = requestStore.outgoingRequests.first(where: { $0.id == stayRequestID }) {
                return stay.listingLabel
            }
            return "this listing"
        case .editing(let note):
            if let home = homeStore.listings.first(where: { $0.id == note.subjectID }) {
                return home.displayTitle
            }
            return "this listing"
        }
    }

    /// The other party's name: the host's listing name for a guest, the guest's profile name for a host.
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
        onComplete: (() -> Void)? = nil,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil
    ) -> some View {
        Group {
            // Rows with inline Yes/No aren't wrapped; the tap target would swallow the buttons.
            if let home = listing(for: request), onAccept == nil {
                NavigationLink { HomeDetailPage(home: home) } label: {
                    OutgoingRequestRow(request: request, onCancel: onCancel, onModify: onModify, onShare: onShare, onComplete: onComplete)
                }
            } else {
                OutgoingRequestRow(
                    request: request,
                    onCancel: onCancel,
                    onModify: onModify,
                    onShare: onShare,
                    onComplete: onComplete,
                    onAccept: onAccept,
                    onDecline: onDecline
                )
            }
        }
        .stayConversationActions(name: subjectName(for: request)) {
            openConversation(for: request)
        }
    }

    /// Wraps an IncomingRequestRow in a NavigationLink if the listing is cached.
    /// Rows with inline Accept/Decline aren't wrapped, for the same reason.
    @ViewBuilder
    private func incomingRow(
        _ request: StayRequest,
        showActions: Bool = false,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) -> some View {
        let home = listing(for: request)
        // Show the street when the host has several listings, to tell requests apart.
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
            onComplete: onComplete,
            onCancel: onCancel
        )
        Group {
            if !showActions, let home {
                NavigationLink { HomeDetailPage(home: home) } label: { row }
            } else {
                row
            }
        }
        .stayConversationActions(name: guestName(for: request)) {
            openConversation(for: request)
        }
    }

    // MARK: - Helpers

    /// Looks up the full Home object for a request from the cached listings.
    private func listing(for request: StayRequest) -> Home? {
        homeStore.listings.first { $0.id == request.listingID }
    }

    /// Hands the other party's thread to the deep-link router, as a push tap does.
    private func openConversation(for request: StayRequest) {
        router.pendingConversationUserID =
            request.hostUserID == authManager.userID ? request.guestUserID : request.hostUserID
    }
}

// Every stay row gets a jump into the conversation: a swipe plus a context menu, as in YourListingsPage.
private extension View {
    func stayConversationActions(name: String, open: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(action: open) {
                    Label("Message", systemImage: "message")
                }
                .tint(.accent)
            }
            .contextMenu {
                Button(action: open) {
                    Label("Message \(name)", systemImage: "message")
                }
            }
    }
}

// MARK: - Mode switcher

/// Two full-width filled pills replacing the system segmented control, which
/// went unnoticed in the nav bar; a badge marks the pane that owes the user something.
private struct StaysModeSwitcher: View {
    @Binding var selection: StaysTab.StaysTabSelection
    let tripsBadge: Int
    let listingsBadge: Int

    var body: some View {
        HStack(spacing: 8) {
            segment(
                title: "My Trips",
                systemImage: "suitcase.fill",
                badge: tripsBadge,
                isSelected: selection == .trips
            ) {
                selection = .trips
            }
            segment(
                title: "My Listings",
                systemImage: "house.fill",
                badge: listingsBadge,
                isSelected: selection == .listings
            ) {
                selection = .listings
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.primaryBackground)
    }

    private func segment(
        title: String,
        systemImage: String,
        badge: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.onAccent.opacity(0.3) : Color.callToAction, in: Capsule())
                        .foregroundColor(isSelected ? Color.onAccent : .white)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(isSelected ? Color.onAccent : .primary)
            .background(
                isSelected ? Color.accent : Color.secondaryBackground,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) need\(badge == 1 ? "s" : "") your attention" : title)
    }
}

#Preview {
    NavigationStack {
        StaysTab()
    }
    .previewEnvironment()
}

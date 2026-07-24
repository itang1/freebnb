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
    @Environment(FriendNoteStore.self) private var noteStore
    @Environment(DeepLinkRouter.self) private var router
    @State private var respondingTo: StayRequest?
    @State private var reviewing: ReviewTarget?
    @State private var notingStay: FriendNoteComposition?
    @State private var thanking: StayRequest?
    @State private var sharingStay: StayRequest?
    @State private var modifying: StayRequest?
    @State private var completing: StayRequest?
    // An accepted stay someone is about to call off. Cancelling a confirmed stay
    // is consequential for both parties, so unlike a pending request it asks
    // first; pending cancels stay immediate.
    @State private var cancelling: StayRequest?
    @State private var actionError: String?
    @State private var selectedTab: StaysTabSelection = .trips
    @State private var showPastTrips = false
    @State private var showPastHosting = false

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
    /// Offers a friend has made this user, which they owe an answer to
    /// (feature 43). The only thing in the traveler pane that is waiting on *them*
    /// rather than on somebody else, which is why it sits at the top.
    private var offeredOut:  [StayRequest] { requestStore.outgoingRequests.filter { $0.status == .offered  } }

    // Incoming (host)
    private var pendingIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .pending  } }
    private var acceptedIn: [StayRequest] { requestStore.incomingRequests.filter { $0.status == .accepted } }
    private var pastIn:     [StayRequest] { requestStore.incomingRequests.filter { !$0.status.isActive   } }
    /// Offers this user has made that a friend hasn't answered yet.
    private var offeredIn:  [StayRequest] { requestStore.incomingRequests.filter { $0.status == .offered  } }

    // The trip timeline splits accepted stays into the one under way right now
    // and the ones still ahead (feature 21), so a stay you're in the middle of
    // rises to the top instead of sitting in a flat "confirmed" list.
    private var inProgressOut: [StayRequest] { acceptedOut.filter { $0.isUnderway() } }
    private var upcomingOut:   [StayRequest] { acceptedOut.filter { !$0.isUnderway() } }
    private var inProgressIn:  [StayRequest] { acceptedIn.filter { $0.isUnderway() } }
    private var upcomingIn:    [StayRequest] { acceptedIn.filter { !$0.isUnderway() } }

    /// The single stay currently live enough to headline (feature 21): an accepted
    /// stay with a real `StayPhase` — arriving today, under way, or checking out
    /// today — and among those the soonest check-in. Deliberately the same
    /// selection the Live Activity uses, so the in-app banner and the Lock Screen
    /// never point at different stays. Paired with its phase so the banner and the
    /// activity share one source of truth for the copy.
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

    /// Finished stays this user hasn't reviewed yet (features 1 and 4). Empty
    /// until `ReviewStore` knows what they've already written, so nobody is asked
    /// twice for a review they already left.
    private var awaitingReview: [StayRequest] {
        requestStore.completedStays.filter { reviewStore.needsReview(stayRequestID: $0.id) }
    }

    // Gates the empty state for My Trips specifically (traveler side only) — a
    // host with pending requests but no trips of their own should still see
    // "No trips yet" here; their requests live under My Listings instead.
    private var hasTripsContent: Bool {
        !pendingOut.isEmpty || !acceptedOut.isEmpty || !pastOut.isEmpty
    }

    var body: some View {
        // Resolved once per body pass and handed down to the panes. Each read of
        // `awaitingReview` re-derives `completedStays` — concatenating both
        // request lists, filtering, and sorting — and the two badges plus each
        // pane's review section read it three times per render.
        let awaiting = awaitingReview
        let reviewsAsGuest = awaiting.filter { $0.guestUserID == authManager.userID }
        let reviewsAsHost = awaiting.filter { $0.hostUserID == authManager.userID }
        let pendingInCount = pendingIn.count
        VStack(spacing: 0) {
            // A big, filled pill per pane rather than the system segmented
            // control: that one sat quietly in the nav bar under a static
            // "Stays" title and people weren't noticing it moved between two
            // very different screens. Color plus a badge on whichever pane
            // owes you something makes the switch itself worth looking at.
            StaysModeSwitcher(
                selection: $selectedTab,
                tripsBadge: reviewsAsGuest.count,
                listingsBadge: pendingInCount + reviewsAsHost.count
            )

            // Pinned above both panes: a stay you're in the middle of is the one
            // thing worth seeing before you've even chosen Trips vs Listings.
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
                    // Requests against your properties surface here, above the
                    // properties themselves — "My Listings" means everything tied
                    // to homes you host, not just the properties list.
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
    }

    // MARK: - Trips view

    @ViewBuilder
    private func tripsView(awaitingReview: [StayRequest]) -> some View {
        if let error = requestStore.listenerError {
            listenerErrorState(error)
        } else if requestStore.isLoadingIncoming && !hasTripsContent {
            // Not the same as having none: the listener clears the lists on an
            // account switch and refills them a round trip later, and "No trips
            // yet" shown in that gap tells a host their inbox is empty when it
            // isn't.
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

    /// First on the page: a stay is freshest the day it ends, and an unreviewed
    /// stay is the one thing here that both parties are waiting on each other
    /// for. Called once per pane with that pane's role-filtered stays, so a
    /// guest-side review prompt never shows up while you're looking at My
    /// Listings, and vice versa.
    @ViewBuilder
    private func reviewSection(_ items: [StayRequest]) -> some View {
        if !items.isEmpty {
            Section("Needs your review") {
                ForEach(items, id: \.id) { req in
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
        // Above "Waiting to hear back" on purpose: everything below is this user
        // waiting on somebody else, and this is the one thing somebody else is
        // waiting on them for.
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
                        // Plans change; a confirmed trip can be called off, with
                        // a confirmation because it affects the host too.
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
                        // A host can no longer honor a stay sometimes (illness, a
                        // burst pipe). firestore.rules admits accepted → cancelled
                        // from the host's side for exactly this.
                        onCancel: { cancelling = req }
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

    /// Everything about requests against your properties: reviews owed, live
    /// hosting sections, and past hosting. Injected above the properties list
    /// in `YourListingsPage` so "My Listings" reads as one coherent screen
    /// about your homes, requests included, rather than requests hiding under
    /// "My Trips" while this pane only manages listing settings.
    @ViewBuilder
    private func listingsRequestSections(awaitingReview: [StayRequest]) -> some View {
        reviewSection(awaitingReview)
        noteSection
        hostSections
        pastHostingSection
    }

    /// Stays this host finished and hasn't been asked about yet. Host side only:
    /// notes are a host's record of their own friends, and there is no guest-side
    /// twin of this anywhere in the feature.
    ///
    /// Deliberately below "Needs your review" and above everything else. A review
    /// is something the other person is waiting on; this is not, and it should
    /// never look like it is.
    private var completedStaysToNoteAbout: [StayRequest] {
        requestStore.completedStays.filter {
            $0.hostUserID == authManager.userID && noteStore.shouldPrompt(forStayRequestID: $0.id)
        }
    }

    /// The optional add-a-note moment: an ordinary row in the list, offered once
    /// per stay, dismissible, and never a modal that stands between the host and
    /// the rest of the screen. If they ignore it forever, nothing happens; if
    /// they wave it off, it does not come back, and they can still write a note
    /// from that friend's screen whenever they like.
    @ViewBuilder
    private var noteSection: some View {
        let items = completedStaysToNoteAbout
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.id) { req in
                    NotePromptRow(
                        guestName: guestName(for: req),
                        dateRange: req.dateRangeText,
                        onAdd: {
                            notingStay = .new(friendID: req.guestUserID, stayRequestID: req.id)
                        },
                        onDismiss: {
                            Task { await noteStore.dismissPrompt(forStayRequestID: req.id) }
                        }
                    )
                }
            } header: {
                Text("Anything to remember?")
            } footer: {
                Text("A note for yourself, if it's useful. Nobody else ever reads it, and skipping is the same as writing nothing.")
            }
        }
    }
}

/// The post-stay prompt. Two plain choices, neither of them urgent: the ask is
/// an offer, so "Not this time" is a real answer and is styled as one rather
/// than as a dismissal the host has to hunt for.
private struct NotePromptRow: View {
    let guestName: String
    let dateRange: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(guestName) stayed with you")
                    .font(.subheadline.weight(.medium))
                Text(dateRange)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            HStack(spacing: 12) {
                Button(action: onAdd) {
                    Label("Add a private note", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Color.accent.opacity(0.12), in: Capsule())
                        .foregroundColor(Color.accent)
                }
                .buttonStyle(.plain)

                Button("Not this time", action: onDismiss)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// Actions, row builders, and lookups live in a same-file extension rather than
// in the struct body: extensions do not count toward SwiftLint's type_body_length,
// and `private` is file-scoped, so they still see the view's state.
extension StaysTab {
    // MARK: - Actions

    /// Cancels a request or an accepted stay, from either side. The chat event
    /// goes to the other party, whoever that is: the host when a guest cancels,
    /// the guest when a host calls a stay off.
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

    /// Returns nil on success, or the failure message for `AcceptSheet` to show.
    /// The sheet dismisses itself once this returns nil.
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
            return error.localizedDescription
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

    /// The guest says yes to a host's offer (feature 43). Goes through the same
    /// callable a host's accept does, so the same transaction guards the same
    /// room: the offer may have sat for days while another guest was accepted for
    /// those dates, and only the server can see that.
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

    /// Who a note being composed here is about. Only ever a guest of the host's:
    /// the prompt is offered on the hosting side alone, so the composition's
    /// friend id is always the person who stayed.
    private func noteSubjectName(for composition: FriendNoteComposition) -> String {
        switch composition {
        case .new(let friendID, _):
            return userProfileStore.displayName(for: friendID) ?? "FreeBNB User"
        case .editing(let note):
            return userProfileStore.displayName(for: note.subjectUserID) ?? "FreeBNB User"
        }
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
        onComplete: (() -> Void)? = nil,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil
    ) -> some View {
        Group {
            // A row carrying inline Yes/No is never wrapped in a NavigationLink,
            // for the same reason the incoming rows aren't: the full-width tap
            // target would swallow the buttons.
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
    /// Rows with inline Accept/Decline actions are never wrapped — full-width
    /// buttons would cover the entire tap area and prevent navigation.
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

    /// Hands the other party's thread to the deep-link router; ContentView
    /// consumes it, switches to the Messages tab, and pushes the conversation
    /// (the same route a push-notification tap takes).
    private func openConversation(for request: StayRequest) {
        router.pendingConversationUserID =
            request.hostUserID == authManager.userID ? request.guestUserID : request.hostUserID
    }
}

// The stay/chat link now runs both ways: threads already pin the request banner
// with accept/decline, and this gives every stay row the reverse jump into the
// conversation. A swipe for speed plus a context menu for discoverability, the
// same pairing YourListingsPage uses.
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

/// Two full-width filled pills standing in for the system segmented control.
/// The accent fill on whichever pane is active, plus a badge on whichever pane
/// owes the user something, is meant to be noticed at a glance — the system
/// segmented control, tucked into the nav bar under a static title, wasn't.
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

//
//  StayRequestStore.swift
//  freebnb
//

import FirebaseAuth
import Foundation
import Observation
import os

@MainActor
@Observable
final class StayRequestStore {
    /// Requests awaiting this user as a host: the ones aimed at listings they own,
    /// merged with the ones aimed at listings they co-host (feature 14).
    var incomingRequests: [StayRequest] {
        var seen = Set<String>()
        return (hostedRequests + coHostedRequests)
            .filter { seen.insert($0.id).inserted }
            .sortedByDate()
    }

    /// Requests naming this user in `hostUserID` — the listings they own.
    private(set) var hostedRequests: [StayRequest] = []
    /// Requests for listings this user co-hosts. Kept apart from `hostedRequests`
    /// because they arrive from a different query keyed on the listing, and the
    /// two listeners settle independently.
    private(set) var coHostedRequests: [StayRequest] = []
    private(set) var outgoingRequests: [StayRequest] = []

    /// True until every listener feeding `incomingRequests` has delivered its
    /// first snapshot for the current user. Host surfaces read this to tell
    /// "still arriving" from "none came in": on an account switch the lists above
    /// are cleared synchronously and refill a round trip later, and an empty
    /// inbox rendered during that window reads as though a request that exists
    /// never arrived.
    ///
    /// Both halves count, not just the owned one. A pure co-host owns no
    /// listings, so the hosted listener answers "none" instantly while the
    /// listing-scoped query is still in flight — exactly the person for whom a
    /// premature "no requests yet" is the whole bug.
    var isLoadingIncoming: Bool { isLoadingHosted || isLoadingCoHosted }

    private var isLoadingHosted = false
    private var isLoadingCoHosted = false
    /// Who the requests above belong to. Observed rather than ignored: the tab
    /// badge is derived from it, so it has to invalidate the view when it changes.
    /// Empty while signed out.
    private(set) var viewerID: String = ""
    /// Set when a Firestore listener fails — most commonly because security
    /// rules haven't been deployed yet. Cleared when the listener recovers.
    private(set) var listenerError: String?

    @ObservationIgnored private let repository: StayRequestsRepository
    /// Schedules the on-device check-in / checkout reminders (feature 22) from the
    /// accepted stays below. Kept in sync on every snapshot so a cancellation or a
    /// date change withdraws or moves its reminders without any extra plumbing.
    @ObservationIgnored private let reminderScheduler = StayReminderScheduler()
    /// Keeps the current-stay Live Activity (feature 21) in step with the accepted
    /// stays below, the same way `reminderScheduler` keeps the local reminders in
    /// step. Reconciled on every snapshot.
    @ObservationIgnored private let liveActivityController = StayLiveActivityController()
    @ObservationIgnored nonisolated(unsafe) private var incomingListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var outgoingListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var coHostedListener: RepositoryListener?
    /// The co-hosted listing ids the listener above is currently bound to. Held so
    /// a repeat of the same set is a no-op rather than a listener churn.
    @ObservationIgnored private var coHostedListingIDs: [String] = []
    // `nonisolated(unsafe)` for the same reason as other stores: deinit is
    // nonisolated but must tear down these handles, which are thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let log = AppLog.logger("stays")

    init(repository: StayRequestsRepository = FirestoreStayRequestsRepository()) {
        self.repository = repository
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartListeners(userID: user?.uid) }
        }
    }

    deinit {
        incomingListener?.cancel()
        outgoingListener?.cancel()
        coHostedListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Listeners

    private func restartListeners(userID: String?) {
        incomingListener?.cancel(); incomingListener = nil
        outgoingListener?.cancel(); outgoingListener = nil
        coHostedListener?.cancel(); coHostedListener = nil
        hostedRequests = []; coHostedRequests = []; outgoingRequests = []
        // The co-hosted set belongs to the user who just left; the next user's
        // arrives from HomeStore once their managed listings load.
        coHostedListingIDs = []
        viewerID = userID ?? ""
        guard let userID else {
            isLoadingHosted = false
            isLoadingCoHosted = false
            // Signed out: take down the widgets and any running Live Activity so
            // the last user's stay doesn't linger on the Lock Screen.
            publishToWidgetsAndActivities(viewerID: "")
            return
        }
        isLoadingHosted = true
        // No co-hosted listener is bound yet; ContentView supplies the roster
        // once HomeStore has it, and binding flips this back on.
        isLoadingCoHosted = false

        incomingListener = repository.listenToRequests(userID: userID, role: .host) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("incoming snapshot error: \(error.localizedDescription, privacy: .public)")
                    self?.listenerError = error.localizedDescription
                    // The inbox is no longer loading; it failed. Leaving the flag
                    // set would spin a skeleton forever over an error nobody sees.
                    self?.isLoadingHosted = false
                case .success(let requests):
                    self?.listenerError = nil
                    self?.hostedRequests = requests.sortedByDate()
                    self?.isLoadingHosted = false
                    self?.syncReminders(viewerID: userID)
                    self?.publishToWidgetsAndActivities(viewerID: userID)
                }
            }
        }

        outgoingListener = repository.listenToRequests(userID: userID, role: .guest) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("outgoing snapshot error: \(error.localizedDescription, privacy: .public)")
                    self?.listenerError = error.localizedDescription
                case .success(let requests):
                    self?.listenerError = nil
                    self?.outgoingRequests = requests.sortedByDate()
                    self?.syncReminders(viewerID: userID)
                    self?.publishToWidgetsAndActivities(viewerID: userID)
                }
            }
        }
    }

    // MARK: - Co-hosted listings (feature 14)

    /// Points the co-hosted listener at the listings this user co-hosts.
    ///
    /// Driven from `ContentView` rather than from here, for the same reason the
    /// check-in kit sync is: which listings a user co-hosts is `HomeStore`'s
    /// question, and a store that answered it itself would need a second copy of
    /// that listener. Idempotent — an unchanged set rebinds nothing.
    func setCoHostedListingIDs(_ listingIDs: [String]) {
        let sorted = listingIDs.sorted()
        guard sorted != coHostedListingIDs else { return }
        coHostedListingIDs = sorted

        coHostedListener?.cancel(); coHostedListener = nil
        guard !sorted.isEmpty else {
            coHostedRequests = []
            isLoadingCoHosted = false
            return
        }
        let userID = viewerID
        guard !userID.isEmpty else {
            isLoadingCoHosted = false
            return
        }
        isLoadingCoHosted = true

        coHostedListener = repository.listenToCoHostedRequests(listingIDs: sorted) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("co-hosted snapshot error: \(error.localizedDescription, privacy: .public)")
                    self?.listenerError = error.localizedDescription
                    self?.isLoadingCoHosted = false
                case .success(let requests):
                    self?.listenerError = nil
                    // A co-host is not a party to the stay, so their own outgoing
                    // request for the listing they co-host must not double back
                    // into their host inbox as something to answer.
                    self?.coHostedRequests = requests
                        .filter { $0.guestUserID != userID }
                        .sortedByDate()
                    self?.isLoadingCoHosted = false
                    self?.syncReminders(viewerID: userID)
                    self?.publishToWidgetsAndActivities(viewerID: userID)
                }
            }
        }
    }

    /// Re-reconciles the local reminder schedule with the currently-accepted
    /// stays across both directions. Cheap and idempotent, so calling it on every
    /// snapshot (from either listener) is fine.
    private func syncReminders(viewerID: String) {
        let accepted = (incomingRequests + outgoingRequests).filter { $0.status == .accepted }
        Task { await reminderScheduler.sync(acceptedStays: accepted, viewerID: viewerID) }
    }

    /// Republishes the home-screen widget snapshot and reconciles the current-stay
    /// Live Activity. Called on every snapshot (and on sign-out with an empty
    /// viewerID to tear both down). Cheap and idempotent, like `syncReminders`.
    private func publishToWidgetsAndActivities(viewerID: String) {
        StayWidgetBridge.publish(
            incoming: incomingRequests,
            outgoing: outgoingRequests,
            viewerID: viewerID
        )
        liveActivityController.sync(
            activeStays: (incomingRequests + outgoingRequests).filter { $0.status == .accepted },
            viewerID: viewerID
        )
    }

    // MARK: - Reload

    /// Restart both listeners with the current authenticated user. Call this
    /// from UI when the listener previously failed (e.g. rules not yet deployed).
    func reload() {
        restartListeners(userID: Auth.auth().currentUser?.uid)
    }

    // MARK: - Guest actions

    func send(
        listing: Home,
        guestUserID: String,
        checkIn: Date,
        checkOut: Date,
        guestNote: String?,
        guestCount: Int? = nil,
        arrivalWindow: ArrivalWindow? = nil,
        advancing counter: StayCounter? = nil
    ) async throws {
        let trimmedNote = guestNote.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let request = StayRequest(
            listingID: listing.id,
            listingCity: listing.address.city,
            listingTitle: listing.title,
            listingHostName: listing.hostName,
            hostUserID: listing.hostUserID,
            guestUserID: guestUserID,
            checkIn: checkIn,
            checkOut: checkOut,
            guestNote: trimmedNote,
            guestCount: guestCount,
            arrivalWindow: arrivalWindow
        )
        do {
            try await repository.create(request, advancing: counter)
            Telemetry.log(.stayRequestSent)
        } catch {
            log.error("send error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Either party may call off a stay, so the write records which one did:
    /// the rules pin `cancelledBy` to the caller, and the push trigger reads it
    /// to tell the other party.
    func cancel(_ request: StayRequest) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StayRequestError.notSignedIn
        }
        try await update(request, status: .cancelled, hostNote: nil, cancelledBy: uid)
    }

    /// Changes the dates on a still-pending request (feature 23). Only the guest
    /// who created it may call this, and only while it is pending — the same
    /// bounds `firestore.rules` enforces.
    func modifyDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws {
        do {
            try await repository.updateDates(request, checkIn: checkIn, checkOut: checkOut)
        } catch {
            log.error("modify dates error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Propagates a host's display-name change to `listingHostName` on every
    /// request they host, so trip rows don't keep showing the old name (L7).
    func updateHostName(for hostUserID: String, newName: String) async throws {
        do {
            try await repository.updateListingHostName(hostUserID: hostUserID, newName: newName)
        } catch {
            log.error("update host name error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Host actions

    /// Offers the listing to a friend for specific dates (feature 43): the mirror
    /// of `send(listing:...)`, originated by the host.
    ///
    /// The document is the same shape a guest's request has — same two parties,
    /// same dates — because it becomes the same stay. Only `status` and
    /// `initiatedBy` record which way it was pointing when it started.
    func offer(
        listing: Home,
        guestUserID: String,
        checkIn: Date,
        checkOut: Date,
        hostNote: String?
    ) async throws {
        let trimmedNote = hostNote.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let request = StayRequest(
            listingID: listing.id,
            listingCity: listing.address.city,
            listingTitle: listing.title,
            listingHostName: listing.hostName,
            hostUserID: listing.hostUserID,
            guestUserID: guestUserID,
            checkIn: checkIn,
            checkOut: checkOut,
            hostNote: trimmedNote,
            status: .offered,
            initiatedBy: listing.hostUserID
        )
        do {
            // No counter: a circle policy governs what a friend may *ask* for,
            // and a host offering their own place is not asking. The rules apply
            // the policy to the guest branch of `create` only, for the same
            // reason.
            try await repository.create(request, advancing: nil)
            Telemetry.log(.stayOfferSent)
        } catch {
            log.error("offer error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Answering (either side)

    /// Says yes. The host accepting a guest's request, or the guest accepting a
    /// host's offer — the callable works out which and runs the same atomic
    /// double-booking guard either way, because an offer books the same room.
    func accept(_ request: StayRequest, hostNote: String? = nil) async throws {
        do {
            try await repository.accept(request, hostNote: hostNote)
            Telemetry.log(.stayRequestAccepted)
        } catch {
            log.error("accept error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A host turns down a guest's request, with an optional note explaining why.
    func decline(_ request: StayRequest, hostNote: String? = nil) async throws {
        try await update(request, status: .declined, hostNote: hostNote)
    }

    /// A guest turns down a host's offer (feature 43).
    ///
    /// Separate from `decline` rather than one role-sniffing method, because the
    /// two writes are not the same write: the note lands on `guestNote` here and
    /// `hostNote` there, and the rules pin each branch to its own key. Naming the
    /// caller's role at the call site is also what keeps this store from having to
    /// ask `Auth` who is holding the phone.
    func declineOffer(_ request: StayRequest, guestNote: String? = nil) async throws {
        try await update(request, status: .declined, hostNote: nil, guestNote: guestNote)
    }

    /// A host takes back an offer the guest hasn't answered. Cancelled, not
    /// declined: it was the host's to retract, and "declined" would read on the
    /// guest's trip list as though they had turned it down.
    func withdrawOffer(_ request: StayRequest, hostNote: String? = nil) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StayRequestError.notSignedIn
        }
        try await update(request, status: .cancelled, hostNote: hostNote, cancelledBy: uid)
    }

    // MARK: - Completion (feature 4)

    /// Closes out a stay that has begun, from either side. Completion is what
    /// unlocks reviews and what the server counts into both parties' trust stats.
    func markCompleted(_ request: StayRequest) async throws {
        do {
            try await repository.markCompleted(request)
        } catch {
            log.error("mark completed error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Stays either side may close out right now: accepted, and under way.
    var completableStays: [StayRequest] {
        (incomingRequests + outgoingRequests).filter { $0.canBeMarkedComplete() }
    }

    /// Finished stays, newest first — the ones that can be reviewed. Whether a
    /// given one *still needs* a review is `ReviewStore`'s question, not this
    /// store's; it depends on what the signed-in user has already written.
    var completedStays: [StayRequest] {
        (incomingRequests + outgoingRequests)
            .filter { $0.status == .completed }
            .sortedByDate()
    }

    // MARK: - Convenience

    /// Returns the most recent active (pending or accepted) request the guest
    /// has sent for a given listing, if any.
    func activeRequest(for listingID: String, guestUserID: String) -> StayRequest? {
        outgoingRequests.first {
            $0.listingID == listingID &&
            $0.guestUserID == guestUserID &&
            $0.status.isActive
        }
    }

    /// Unresolved stays on listings this user hosts: guests' requests they owe an
    /// answer to, plus offers they made that a friend hasn't answered.
    var pendingIncomingCount: Int {
        incomingRequests.filter { $0.status.isAwaitingReply }.count
    }

    /// Unresolved stays where this user is the guest: requests they sent that a
    /// host hasn't answered, plus offers a host made them (feature 43).
    var pendingOutgoingCount: Int {
        outgoingRequests.filter { $0.status.isAwaitingReply }.count
    }

    /// The Stays tab badge: stays waiting on *this user's* answer, and nothing
    /// else. A badge is a claim that someone is blocked on you, so a request you
    /// sent and are waiting to hear back on doesn't earn one — you can't clear it,
    /// and a number that won't go down however much you tap it teaches people to
    /// ignore the badge entirely. Both directions still count: a host owes an
    /// answer on an incoming request, and a guest owes one on an offer.
    var pendingStaysTabCount: Int {
        (incomingRequests + outgoingRequests).awaitingReplyCount(from: viewerID)
    }

    /// Offers a host made this user that they haven't answered. The host-initiated
    /// mirror of the incoming requests a host answers, and what the Stays tab's
    /// "Needs your response" section shows a guest (feature 43).
    func offersAwaiting(_ userID: String) -> [StayRequest] {
        outgoingRequests.filter { $0.status == .offered && $0.awaitsReply(from: userID) }.sortedByDate()
    }

    // MARK: - Private

    private func update(
        _ request: StayRequest,
        status: StayRequestStatus,
        hostNote: String?,
        guestNote: String? = nil,
        cancelledBy: String? = nil
    ) async throws {
        do {
            try await repository.updateStatus(
                request,
                status: status,
                hostNote: hostNote,
                guestNote: guestNote,
                cancelledBy: cancelledBy
            )
        } catch {
            log.error("update error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

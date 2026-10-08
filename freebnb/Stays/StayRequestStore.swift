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
    /// Requests awaiting this user as a host: those for listings they own plus
    /// those for listings they co-host.
    var incomingRequests: [StayRequest] {
        var seen = Set<String>()
        return (hostedRequests + coHostedRequests)
            .filter { seen.insert($0.id).inserted }
            .sortedByDate()
    }

    /// Requests naming this user in `hostUserID` (listings they own).
    private(set) var hostedRequests: [StayRequest] = []
    /// Requests for listings this user co-hosts. Separate from `hostedRequests`
    /// because they come from a different query and settle independently.
    private(set) var coHostedRequests: [StayRequest] = []
    private(set) var outgoingRequests: [StayRequest] = []

    /// True until every listener feeding `incomingRequests` has delivered its first
    /// snapshot. Lets host surfaces tell "still arriving" from "none came in", since
    /// the lists are cleared on an account switch and refill a round trip later.
    /// Both halves count: a pure co-host's owned listener answers "none" instantly
    /// while the listing-scoped query is still in flight.
    var isLoadingIncoming: Bool { isLoadingHosted || isLoadingCoHosted }

    /// Whether the lists can be trusted to say a stay does *not* exist. False
    /// while any listener awaits its first snapshot or has failed. Only callers
    /// that act on nothing being there need this.
    var hasLoadedRequests: Bool {
        !isLoadingIncoming && !isLoadingOutgoing && listenerError == nil
    }

    // True from birth: listeners bind from an auth callback, so starting false
    // would call that unbound window a loaded, empty inbox.
    private var isLoadingHosted = true
    private var isLoadingOutgoing = true
    // Stays false: no co-hosted listener exists until ContentView supplies the roster.
    private var isLoadingCoHosted = false
    /// Who the requests belong to. Observed because the tab badge derives from it. Empty when signed out.
    private(set) var viewerID: String = ""
    /// Set when a listener fails (commonly undeployed rules); cleared on recovery.
    private(set) var listenerError: String?

    @ObservationIgnored private let repository: StayRequestsRepository
    /// Schedules on-device check-in/checkout reminders from accepted stays, synced on every snapshot.
    @ObservationIgnored private let reminderScheduler = StayReminderScheduler()
    /// The in-flight reminder reconcile, so the next can wait for it (see `syncReminders`).
    @ObservationIgnored private var reminderSyncTask: Task<Void, Never>?
    /// Keeps the current-stay Live Activity in step with accepted stays, like `reminderScheduler`.
    @ObservationIgnored private let liveActivityController = StayLiveActivityController()
    @ObservationIgnored nonisolated(unsafe) private var incomingListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var outgoingListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var coHostedListener: RepositoryListener?
    /// Co-hosted listing ids the listener is bound to; a repeat of the same set is a no-op.
    @ObservationIgnored private var coHostedListingIDs: [String] = []
    // `nonisolated(unsafe)`: deinit is nonisolated but must tear down these thread-safe handles.
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
        // The co-hosted set belongs to the previous user; HomeStore supplies the next one.
        coHostedListingIDs = []
        viewerID = userID ?? ""
        guard let userID else {
            isLoadingHosted = false
            isLoadingCoHosted = false
            isLoadingOutgoing = false
            // Signed out: clear widgets, any Live Activity and scheduled reminders,
            // so nothing lingers on the Lock Screen (reminders outlive the process).
            publishToWidgetsAndActivities(viewerID: "")
            syncReminders(viewerID: "")
            return
        }
        isLoadingHosted = true
        isLoadingOutgoing = true
        // No co-hosted listener yet; binding flips this back on.
        isLoadingCoHosted = false

        incomingListener = repository.listenToRequests(userID: userID, role: .host) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("incoming snapshot error: \(error.localizedDescription, privacy: .public)")
                    self?.listenerError = error.localizedDescription
                    // Failed, not loading; leaving the flag set would spin a skeleton forever.
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
                    self?.isLoadingOutgoing = false
                case .success(let requests):
                    self?.listenerError = nil
                    self?.outgoingRequests = requests.sortedByDate()
                    self?.isLoadingOutgoing = false
                    self?.syncReminders(viewerID: userID)
                    self?.publishToWidgetsAndActivities(viewerID: userID)
                }
            }
        }
    }

    // MARK: - Co-hosted listings

    /// Points the co-hosted listener at the listings this user co-hosts. Driven
    /// from `ContentView` because `HomeStore` owns that question. Idempotent.
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
                    // A co-host's own outgoing request mustn't appear in their host inbox.
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

    /// Re-reconciles reminders with the accepted stays in both directions.
    /// Cheap and idempotent. Chained after the previous call so the last caller
    /// is the last writer; otherwise a snapshot arriving just before sign-out
    /// could resume afterwards and leak the departing user's reminders.
    private func syncReminders(viewerID: String) {
        let accepted = (incomingRequests + outgoingRequests).filter { $0.status == .accepted }
        let previous = reminderSyncTask
        reminderSyncTask = Task { [reminderScheduler] in
            await previous?.value
            await reminderScheduler.sync(acceptedStays: accepted, viewerID: viewerID)
        }
    }

    /// Republishes the widget snapshot and reconciles the Live Activity. Runs on
    /// every snapshot, and on sign-out with an empty viewerID to tear both down.
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

    /// Restarts both listeners for the current user; call after a listener failed.
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

    /// Records who cancelled: the rules pin `cancelledBy` to the caller and the
    /// push trigger reads it to notify the other party.
    func cancel(_ request: StayRequest) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StayRequestError.notSignedIn
        }
        try await update(request, status: .cancelled, hostNote: nil, cancelledBy: uid)
    }

    /// Changes the dates on a pending request; guest only, as `firestore.rules` enforces.
    func modifyDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws {
        do {
            try await repository.updateDates(request, checkIn: checkIn, checkOut: checkOut)
        } catch {
            log.error("modify dates error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Propagates a host's display-name change to `listingHostName` on their requests.
    func updateHostName(for hostUserID: String, newName: String) async throws {
        do {
            try await repository.updateListingHostName(hostUserID: hostUserID, newName: newName)
        } catch {
            log.error("update host name error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Host actions

    /// Offers the listing to a friend for specific dates. The document has the
    /// same shape as a guest's request; only `status` and `initiatedBy` differ.
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
            // No counter: a circle policy limits what a friend may ask for, not what a host offers.
            try await repository.create(request, advancing: nil)
            Telemetry.log(.stayOfferSent)
        } catch {
            log.error("offer error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Answering (either side)

    /// Says yes: a host accepting a request or a guest accepting an offer. Both
    /// run the same double-booking guard.
    func accept(_ request: StayRequest, hostNote: String? = nil) async throws {
        do {
            try await repository.accept(request, hostNote: hostNote)
            Telemetry.log(.stayRequestAccepted)
        } catch {
            log.error("accept error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A host turns down a guest's request, with an optional note.
    func decline(_ request: StayRequest, hostNote: String? = nil) async throws {
        try await update(request, status: .declined, hostNote: hostNote)
    }

    /// A guest turns down a host's offer. Separate from `decline` because the note
    /// lands on `guestNote` rather than `hostNote` and the rules pin each to its own key.
    func declineOffer(_ request: StayRequest, guestNote: String? = nil) async throws {
        try await update(request, status: .declined, hostNote: nil, guestNote: guestNote)
    }

    /// A host retracts an unanswered offer. Cancelled, not declined, so the guest
    /// doesn't see it as their own refusal.
    func withdrawOffer(_ request: StayRequest, hostNote: String? = nil) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StayRequestError.notSignedIn
        }
        try await update(request, status: .cancelled, hostNote: hostNote, cancelledBy: uid)
    }

    // MARK: - Completion

    /// Closes out a stay that has begun, from either side; unlocks reviews and trust stats.
    func markCompleted(_ request: StayRequest) async throws {
        do {
            try await repository.markCompleted(request)
        } catch {
            log.error("mark completed error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Accepted stays that are under way.
    var completableStays: [StayRequest] {
        (incomingRequests + outgoingRequests).filter { $0.canBeMarkedComplete() }
    }

    /// Finished stays, newest first. Whether one still needs a review is `ReviewStore`'s call.
    var completedStays: [StayRequest] {
        (incomingRequests + outgoingRequests)
            .filter { $0.status == .completed }
            .sortedByDate()
    }

    // MARK: - Convenience

    /// The guest's most recent active (pending or accepted) request for a listing.
    func activeRequest(for listingID: String, guestUserID: String) -> StayRequest? {
        outgoingRequests.first {
            $0.listingID == listingID &&
            $0.guestUserID == guestUserID &&
            $0.status.isActive
        }
    }

    /// Unresolved stays on listings this user hosts: requests and offers awaiting an answer.
    var pendingIncomingCount: Int {
        incomingRequests.filter { $0.status.isAwaitingReply }.count
    }

    /// Unresolved stays where this user is the guest: requests awaiting a host and offers made to them.
    var pendingOutgoingCount: Int {
        outgoingRequests.filter { $0.status.isAwaitingReply }.count
    }

    /// The Stays tab badge: only stays waiting on this user's answer. Requests
    /// they sent don't count, since they can't clear them.
    var pendingStaysTabCount: Int {
        (incomingRequests + outgoingRequests).awaitingReplyCount(from: viewerID)
    }

    /// Offers a host made this user that they haven't answered.
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

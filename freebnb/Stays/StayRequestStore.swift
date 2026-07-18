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
    private(set) var incomingRequests: [StayRequest] = []
    private(set) var outgoingRequests: [StayRequest] = []
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
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Listeners

    private func restartListeners(userID: String?) {
        incomingListener?.cancel(); incomingListener = nil
        outgoingListener?.cancel(); outgoingListener = nil
        incomingRequests = []; outgoingRequests = []
        viewerID = userID ?? ""
        guard let userID else {
            // Signed out: take down the widgets and any running Live Activity so
            // the last user's stay doesn't linger on the Lock Screen.
            publishToWidgetsAndActivities(viewerID: "")
            return
        }

        incomingListener = repository.listenToRequests(userID: userID, role: .host) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("incoming snapshot error: \(error.localizedDescription, privacy: .public)")
                    self?.listenerError = error.localizedDescription
                case .success(let requests):
                    self?.listenerError = nil
                    self?.incomingRequests = requests.sortedByDate()
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
        arrivalWindow: ArrivalWindow? = nil
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
            try await repository.create(request)
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
            try await repository.create(request)
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

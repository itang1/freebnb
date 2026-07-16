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

    func cancel(_ request: StayRequest) async throws {
        try await update(request, status: .cancelled, hostNote: nil)
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

    func accept(_ request: StayRequest, hostNote: String? = nil) async throws {
        do {
            // Guards against accepting a request that double-books the listing.
            try await repository.accept(request, hostNote: hostNote)
            Telemetry.log(.stayRequestAccepted)
        } catch {
            log.error("accept error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func decline(_ request: StayRequest, hostNote: String? = nil) async throws {
        try await update(request, status: .declined, hostNote: hostNote)
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

    var pendingIncomingCount: Int {
        incomingRequests.filter { $0.status == .pending }.count
    }

    var pendingOutgoingCount: Int {
        outgoingRequests.filter { $0.status == .pending }.count
    }

    /// Total shown as the Stays tab badge: pending requests in either direction.
    var pendingStaysTabCount: Int {
        pendingIncomingCount + pendingOutgoingCount
    }

    // MARK: - Private

    private func update(_ request: StayRequest, status: StayRequestStatus, hostNote: String?) async throws {
        do {
            try await repository.updateStatus(request, status: status, hostNote: hostNote)
        } catch {
            log.error("update error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

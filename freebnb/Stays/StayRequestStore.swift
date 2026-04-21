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

    @ObservationIgnored private let repository: StayRequestsRepository
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
        guard let userID else { return }

        incomingListener = repository.listenToRequests(userID: userID, role: .host) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("incoming snapshot error: \(error.localizedDescription, privacy: .public)")
                case .success(let requests):
                    self?.incomingRequests = requests
                }
            }
        }

        outgoingListener = repository.listenToRequests(userID: userID, role: .guest) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .failure(let error):
                    self?.log.error("outgoing snapshot error: \(error.localizedDescription, privacy: .public)")
                case .success(let requests):
                    self?.outgoingRequests = requests
                }
            }
        }
    }

    // MARK: - Guest actions

    func send(
        listing: Home,
        guestUserID: String,
        checkIn: Date,
        checkOut: Date,
        guestNote: String?
    ) async throws {
        let trimmedNote = guestNote.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let request = StayRequest(
            listingID: listing.id,
            listingCity: listing.address.city,
            listingHostName: listing.hostName,
            hostUserID: listing.hostUserID,
            guestUserID: guestUserID,
            checkIn: checkIn,
            checkOut: checkOut,
            guestNote: trimmedNote
        )
        do {
            try await repository.create(request)
        } catch {
            log.error("send error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func cancel(_ request: StayRequest) async throws {
        try await update(requestID: request.id, status: .cancelled, hostNote: nil)
    }

    // MARK: - Host actions

    func accept(_ request: StayRequest, hostNote: String? = nil) async throws {
        try await update(requestID: request.id, status: .accepted, hostNote: hostNote)
    }

    func decline(_ request: StayRequest, hostNote: String? = nil) async throws {
        try await update(requestID: request.id, status: .declined, hostNote: hostNote)
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

    private func update(requestID: String, status: StayRequestStatus, hostNote: String?) async throws {
        do {
            try await repository.updateStatus(requestID: requestID, status: status, hostNote: hostNote)
        } catch {
            log.error("update error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

//
//  FriendStore.swift
//  freebnb
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

// MARK: - Model

enum FriendStatus: String, Codable, Hashable, Sendable {
    case pending, accepted
}

struct FriendEdge: Identifiable, Codable, Hashable, Sendable {
    @DocumentID var id: String?
    var userA: String      // alphabetically smaller UID
    var userB: String      // alphabetically larger UID
    var status: FriendStatus
    var initiator: String  // UID who sent the request
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    func otherUserID(relativeTo myID: String) -> String {
        userA == myID ? userB : userA
    }

    static func edgeID(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }
}

/// A "people you may know" candidate returned by the `suggestFriends` callable:
/// a friend-of-a-friend with a count of how many friends they share (feature 31).
struct FriendSuggestion: Identifiable, Hashable, Sendable {
    let userID: String
    let displayName: String
    let mutualCount: Int
    var id: String { userID }
}

// MARK: - Store

@MainActor
@Observable
final class FriendStore {
    private(set) var allEdges: [FriendEdge] = []
    private(set) var listenerError: String?
    private(set) var suggestions: [FriendSuggestion] = []

    @ObservationIgnored private let repository: FriendEdgeRepository
    @ObservationIgnored nonisolated(unsafe) private var listenerA: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var listenerB: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    // Edges for each listener half; merged into allEdges.
    @ObservationIgnored private var edgesA: [String: FriendEdge] = [:]
    @ObservationIgnored private var edgesB: [String: FriendEdge] = [:]
    @ObservationIgnored private let log = AppLog.logger("friends")

    init(repository: FriendEdgeRepository = FirestoreFriendEdgeRepository()) {
        self.repository = repository
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.isAnonymous == false ? user?.uid : nil
            Task { @MainActor in self?.restartListeners(userID: uid) }
        }
    }

    deinit {
        listenerA?.cancel()
        listenerB?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Derived views

    var friendEdges: [FriendEdge] {
        allEdges.filter { $0.status == .accepted }
    }

    var pendingIncoming: [FriendEdge] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }
        return allEdges.filter { $0.status == .pending && $0.initiator != uid }
    }

    var pendingOutgoing: [FriendEdge] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }
        return allEdges.filter { $0.status == .pending && $0.initiator == uid }
    }

    var pendingCount: Int { pendingIncoming.count }

    /// UIDs of everyone the signed-in user is actually friends with. Stamped onto
    /// a listing's `allowedViewerIDs` on save so the rules can enforce friends-only
    /// visibility without joining to `friendEdges`.
    var friendIDs: [String] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }
        return friendEdges.map { $0.otherUserID(relativeTo: uid) }
    }

    func isFriend(_ userID: String) -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        return friendEdges.contains { $0.otherUserID(relativeTo: uid) == userID }
    }

    func existingEdge(with userID: String) -> FriendEdge? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return allEdges.first { $0.otherUserID(relativeTo: uid) == userID }
    }

    // MARK: - Listeners

    private func restartListeners(userID: String?) {
        listenerA?.cancel(); listenerA = nil
        listenerB?.cancel(); listenerB = nil
        guard let userID else {
            allEdges = []; edgesA = [:]; edgesB = [:]
            return
        }
        listenerA = repository.listenToEdges(userID: userID, field: "userA") { [weak self] result in
            Task { @MainActor [weak self] in self?.applyEdges(result, side: "A") }
        }
        listenerB = repository.listenToEdges(userID: userID, field: "userB") { [weak self] result in
            Task { @MainActor [weak self] in self?.applyEdges(result, side: "B") }
        }
    }

    private func applyEdges(_ result: Result<[FriendEdge], Error>, side: String) {
        switch result {
        case .success(let edges):
            let dict = Dictionary(uniqueKeysWithValues: edges.compactMap { e -> (String, FriendEdge)? in
                guard let id = e.id else { return nil }
                return (id, e)
            })
            if side == "A" { edgesA = dict } else { edgesB = dict }
            var merged = edgesA
            merged.merge(edgesB) { _, new in new }
            allEdges = merged.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .failure(let error):
            log.error("friend edge listener \(side) error: \(error.localizedDescription, privacy: .public)")
            listenerError = error.localizedDescription
        }
    }

    // MARK: - Actions

    /// Loads "people you may know" from the callable, dropping anyone a live edge
    /// already covers (the graph may have changed since the server computed it).
    func loadSuggestions() async {
        guard Auth.auth().currentUser?.uid != nil else {
            suggestions = []
            return
        }
        do {
            let fetched = try await repository.fetchSuggestions()
            let connected = Set(allEdges.flatMap { [$0.userA, $0.userB] })
            suggestions = fetched.filter { !connected.contains($0.userID) }
        } catch {
            log.error("friend suggestions error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a suggestion locally once acted on, so the card disappears without
    /// waiting for a re-fetch.
    func dismissSuggestion(_ userID: String) {
        suggestions.removeAll { $0.userID == userID }
    }

    func sendRequest(to recipientID: String) async throws {
        guard let myID = Auth.auth().currentUser?.uid else { return }
        guard myID != recipientID else { return }
        let sorted = [myID, recipientID].sorted()
        let edge = FriendEdge(
            userA: sorted[0],
            userB: sorted[1],
            status: .pending,
            initiator: myID
        )
        try await repository.createEdge(edge)
    }

    func accept(_ edge: FriendEdge) async throws {
        guard let id = edge.id else { return }
        try await repository.updateStatus(edgeID: id, status: .accepted)
    }

    func decline(_ edge: FriendEdge) async throws {
        guard let id = edge.id else { return }
        try await repository.deleteEdge(edgeID: id)
    }

    func remove(_ edge: FriendEdge) async throws {
        guard let id = edge.id else { return }
        try await repository.deleteEdge(edgeID: id)
    }
}

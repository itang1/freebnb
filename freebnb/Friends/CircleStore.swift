//
//  CircleStore.swift
//  freebnb
//
//  The host's own view of Circles: their circles, who is in each, and the
//  per-friend overrides. Host-side only — nothing here is ever read by a guest,
//  and no screen a guest can reach touches this store.
//
//  It also owns the two pieces of reconciliation that keep the model's promises
//  true without a deployed server:
//
//    - a host with no circles gets the three starter ones on first sight;
//    - a friend with no membership document gets one naming Default, which is
//      what "new friends land in Default automatically" means in practice.
//
//  Both are idempotent, both run from the host's own device, and both are
//  mirrored by `onFriendEdgeWritten` for the day functions are deployed.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

@MainActor
@Observable
final class CircleStore {
    private(set) var circles: [FriendCircle] = []
    private(set) var membershipsByFriendID: [String: CircleMembership] = [:]
    private(set) var listenerError: String?
    /// False until both listeners have delivered a first snapshot. The
    /// reconciliation below waits on it: seeding circles because an empty
    /// snapshot has not arrived yet would write three documents the host
    /// already has.
    private(set) var hasLoaded = false

    @ObservationIgnored private let repository: CircleRepository
    @ObservationIgnored nonisolated(unsafe) private var circlesListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var membersListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var hostID: String = ""
    @ObservationIgnored private var didLoadCircles = false
    @ObservationIgnored private var didLoadMembers = false
    /// Friend ids a membership write is already in flight for, so a snapshot
    /// arriving mid-write doesn't start a second one.
    @ObservationIgnored private var reconciling: Set<String> = []
    @ObservationIgnored private var isSeeding = false
    @ObservationIgnored private let log = AppLog.logger("circles")

    init(repository: CircleRepository = FirestoreCircleRepository()) {
        self.repository = repository
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.isAnonymous == false ? user?.uid : nil
            Task { @MainActor in self?.restartListeners(userID: uid) }
        }
    }

    deinit {
        circlesListener?.cancel()
        membersListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Derived views

    var defaultCircle: FriendCircle? {
        circles.first { $0.id == FriendCircle.defaultID }
    }

    func circle(id: String) -> FriendCircle? {
        circles.first { $0.id == id }
    }

    func membership(for friendID: String) -> CircleMembership? {
        membershipsByFriendID[friendID]
    }

    /// The policy governing `friendID`, and where it came from. The host-facing
    /// twin of what `firestore.rules` resolves on every booking.
    func resolved(for friendID: String) -> (policy: BookingPolicy, source: CirclePolicyResolver.Source) {
        CirclePolicyResolver.resolve(membership: membershipsByFriendID[friendID], circles: circles)
    }

    /// Friend ids currently filed under `circleID`, including the ones resolving
    /// there by fallback when that circle is Default.
    func memberIDs(of circleID: String, among friendIDs: [String]) -> [String] {
        friendIDs.filter { friendID in
            guard let membership = membershipsByFriendID[friendID] else {
                return circleID == FriendCircle.defaultID
            }
            return membership.circleID == circleID
                || (circleID == FriendCircle.defaultID && circle(id: membership.circleID) == nil)
        }
    }

    /// How many friends each circle holds, for the circle list's subtitle.
    func memberCounts(among friendIDs: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for friendID in friendIDs {
            let membership = membershipsByFriendID[friendID]
            let circleID = membership.flatMap { circle(id: $0.circleID)?.id } ?? FriendCircle.defaultID
            counts[circleID, default: 0] += 1
        }
        return counts
    }

    // MARK: - Listeners

    private func restartListeners(userID: String?) {
        circlesListener?.cancel(); circlesListener = nil
        membersListener?.cancel(); membersListener = nil
        circles = []
        membershipsByFriendID = [:]
        reconciling = []
        didLoadCircles = false
        didLoadMembers = false
        hasLoaded = false
        hostID = userID ?? ""
        guard let userID else { return }

        circlesListener = repository.listenToCircles(hostID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let circles):
                    self.circles = circles
                    self.listenerError = nil
                case .failure(let error):
                    self.log.error("circles listener: \(error.localizedDescription, privacy: .public)")
                    self.listenerError = error.localizedDescription
                }
                self.didLoadCircles = true
                self.hasLoaded = self.didLoadCircles && self.didLoadMembers
            }
        }

        membersListener = repository.listenToMemberships(hostID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let memberships):
                    self.membershipsByFriendID = Dictionary(
                        memberships.compactMap { m in m.id.map { ($0, m) } },
                        uniquingKeysWith: { _, new in new }
                    )
                    self.listenerError = nil
                case .failure(let error):
                    self.log.error("memberships listener: \(error.localizedDescription, privacy: .public)")
                    self.listenerError = error.localizedDescription
                }
                self.didLoadMembers = true
                self.hasLoaded = self.didLoadCircles && self.didLoadMembers
            }
        }
    }

    // MARK: - Reconciliation

    /// Seeds a host's starter circles and files any friend who has no membership
    /// under Default. Safe to call on every appearance of the friends screen:
    /// it writes only what is missing, and it does nothing at all until both
    /// listeners have reported.
    ///
    /// Placing a friend explicitly, rather than treating an absent document as
    /// "in Default", is the point: Default is a real circle carrying a real
    /// policy, and a membership nobody wrote is a gap to close, not a state to
    /// read.
    func reconcile(friendIDs: [String]) async {
        guard hasLoaded, !hostID.isEmpty else { return }

        if circles.isEmpty && !isSeeding {
            isSeeding = true
            defer { isSeeding = false }
            do { try await repository.seedCircles(hostID: hostID) }
            catch { log.error("seed circles: \(error.localizedDescription, privacy: .public)") }
            return // the listener will deliver them; placement happens next pass
        }

        let unplaced = friendIDs.filter { membershipsByFriendID[$0] == nil && !reconciling.contains($0) }
        guard !unplaced.isEmpty, let fallback = defaultCircle else { return }
        reconciling.formUnion(unplaced)
        defer { reconciling.subtract(unplaced) }

        for friendID in unplaced {
            do {
                try await repository.saveMembership(
                    hostID: hostID,
                    CircleMembership(id: friendID, circleID: FriendCircle.defaultID),
                    resolvedPolicy: fallback.policy
                )
            } catch {
                log.error("place friend in default: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Circle actions

    func createCircle(named name: String) async throws {
        guard !hostID.isEmpty else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FriendCircle.nameLimit))
        guard !trimmed.isEmpty else { return }
        let circle = FriendCircle(
            id: UUID().uuidString,
            name: trimmed,
            isDefault: false,
            sortOrder: (circles.map(\.sortOrder).max() ?? 0) + 1,
            policy: .permissive
        )
        try await repository.saveCircle(hostID: hostID, circle)
    }

    func rename(_ circle: FriendCircle, to name: String) async throws {
        guard !hostID.isEmpty else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FriendCircle.nameLimit))
        guard !trimmed.isEmpty, trimmed != circle.name else { return }
        var updated = circle
        updated.name = trimmed
        try await repository.saveCircle(hostID: hostID, updated)
    }

    /// Saves a circle's policy and republishes it to everyone the circle governs
    /// — everyone in it who has no override of their own.
    func updatePolicy(of circle: FriendCircle, to policy: BookingPolicy, friendIDs: [String]) async throws {
        guard !hostID.isEmpty, let circleID = circle.id else { return }
        var updated = circle
        updated.policy = policy
        try await repository.saveCircle(hostID: hostID, updated)

        let governed = memberIDs(of: circleID, among: friendIDs)
            .filter { membershipsByFriendID[$0]?.overridePolicy == nil }
        try await repository.publishPolicies(
            hostID: hostID,
            policiesByFriendID: Dictionary(uniqueKeysWithValues: governed.map { ($0, policy) })
        )
    }

    /// Deletes a circle, moving everyone in it back to Default. Refused for
    /// Default itself, which the rules refuse too.
    func delete(_ circle: FriendCircle, friendIDs: [String]) async throws {
        guard !hostID.isEmpty, let circleID = circle.id, circle.isDeletable else { return }
        let members = memberIDs(of: circleID, among: friendIDs)
            .filter { membershipsByFriendID[$0]?.circleID == circleID }
        try await repository.deleteCircle(hostID: hostID, circleID: circleID, movingMembers: members)

        // The moved members are now governed by Default, so their projections
        // have to say so. Anyone with an override keeps theirs.
        if let fallback = defaultCircle {
            let governed = members.filter { membershipsByFriendID[$0]?.overridePolicy == nil }
            try await repository.publishPolicies(
                hostID: hostID,
                policiesByFriendID: Dictionary(uniqueKeysWithValues: governed.map { ($0, fallback.policy) })
            )
        }
    }

    // MARK: - Membership actions

    func assign(friendID: String, to circleID: String) async throws {
        guard !hostID.isEmpty else { return }
        var membership = membershipsByFriendID[friendID] ?? CircleMembership(id: friendID)
        membership.id = friendID
        membership.circleID = circleID
        let policy = membership.overridePolicy ?? circle(id: circleID)?.policy ?? defaultCircle?.policy ?? .permissive
        try await repository.saveMembership(hostID: hostID, membership, resolvedPolicy: policy)
    }

    /// Sets or clears the policy on one friend directly. An override supersedes
    /// their circle for as long as it exists; clearing it hands them back to
    /// whichever circle they are in, which is why the projection is rewritten
    /// from the resolved value rather than from the override.
    func setOverride(_ policy: BookingPolicy?, forFriendID friendID: String) async throws {
        guard !hostID.isEmpty else { return }
        var membership = membershipsByFriendID[friendID] ?? CircleMembership(id: friendID)
        membership.id = friendID
        membership.overridePolicy = policy
        let resolved = policy
            ?? circle(id: membership.circleID)?.policy
            ?? defaultCircle?.policy
            ?? .permissive
        try await repository.saveMembership(hostID: hostID, membership, resolvedPolicy: resolved)
    }
}

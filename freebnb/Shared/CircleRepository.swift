//
//  CircleRepository.swift
//  freebnb
//
//  Reads and writes for Circles, with two audiences kept apart in one file so the
//  asymmetry shows:
//    - the host reads/writes `users/{me}/circles` and `circleMembers` and fans the
//      resolved policy out to `users/{me}/bookingPolicies/{friend}`;
//    - the guest reads one document, their own projection under the host they're about to
//      ask, never the circles.
//  The fan-out is denormalized like a listing's `allowedViewerIDs`; the rules never trust
//  the copy. See docs/internal/CIRCLES.md.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation

protocol CircleRepository: Sendable {
    // MARK: Host side
    func listenToCircles(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendCircle], Error>) -> Void
    ) -> RepositoryListener

    func listenToMemberships(
        hostID: String,
        handler: @escaping @Sendable (Result<[CircleMembership], Error>) -> Void
    ) -> RepositoryListener

    func saveCircle(hostID: String, _ circle: FriendCircle) async throws
    /// Deletes a circle and moves its members back to Default, then refreshes their projections. Never for
    /// Default.
    func deleteCircle(hostID: String, circleID: String, movingMembers members: [String]) async throws
    /// Writes one friend's membership (assignment and/or override) and projection together.
    func saveMembership(hostID: String, _ membership: CircleMembership, resolvedPolicy: BookingPolicy) async throws
    /// Rewrites the projection for a set of friends at once (a circle policy edit's fan-out).
    func publishPolicies(hostID: String, policiesByFriendID: [String: BookingPolicy]) async throws
    /// Creates the three starter circles for a host who has none.
    func seedCircles(hostID: String) async throws

    // MARK: Guest side
    /// The one document a guest may read: the policy this host resolved for them; nil means no restrictions.
    func fetchPolicy(hostID: String, guestID: String) async throws -> BookingPolicy?
    /// The guest's own frequency counter with this host, if any.
    func fetchStayCounter(hostID: String, guestID: String) async throws -> StayCounter?
}

struct FirestoreCircleRepository: CircleRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func circles(_ hostID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(hostID).collection(FirestorePaths.circles)
    }

    private func members(_ hostID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(hostID).collection(FirestorePaths.circleMembers)
    }

    private func policies(_ hostID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(hostID).collection(FirestorePaths.bookingPolicies)
    }

    // MARK: - Host side

    func listenToCircles(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendCircle], Error>) -> Void
    ) -> RepositoryListener {
        let reg = circles(hostID).addSnapshotListener { snapshot, error in
            if let error { handler(.failure(error)); return }
            let circles: [FriendCircle] = (snapshot?.documents ?? []).compactMap { doc in
                do {
                    var circle = try doc.data(as: FriendCircle.self)
                    circle.id = doc.documentID
                    return circle
                } catch {
                    Telemetry.decodeFailure(collection: FirestorePaths.circles, documentID: doc.documentID, error: error)
                    return nil
                }
            }
            handler(.success(circles.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }))
        }
        return FirestoreListenerBox(reg)
    }

    func listenToMemberships(
        hostID: String,
        handler: @escaping @Sendable (Result<[CircleMembership], Error>) -> Void
    ) -> RepositoryListener {
        let reg = members(hostID).addSnapshotListener { snapshot, error in
            if let error { handler(.failure(error)); return }
            let memberships: [CircleMembership] = (snapshot?.documents ?? []).compactMap { doc in
                do {
                    var membership = try doc.data(as: CircleMembership.self)
                    membership.id = doc.documentID
                    return membership
                } catch {
                    Telemetry.decodeFailure(collection: FirestorePaths.circleMembers, documentID: doc.documentID, error: error)
                    return nil
                }
            }
            handler(.success(memberships))
        }
        return FirestoreListenerBox(reg)
    }

    func saveCircle(hostID: String, _ circle: FriendCircle) async throws {
        guard let id = circle.id else { return }
        try await withRetry {
            try circles(hostID).document(id).setData(from: circle, merge: true)
        }
    }

    func deleteCircle(hostID: String, circleID: String, movingMembers members: [String]) async throws {
        guard circleID != FriendCircle.defaultID else { return }
        try await withRetry {
            // One batch, so a friend is never in a deleted circle. Chunked past the batch cap, with
            // the delete in the last chunk so an interrupted run leaves the circle standing.
            let chunks = stride(from: 0, to: max(members.count, 1), by: firestoreBatchLimit / 2).map { start in
                Array(members[start..<min(start + firestoreBatchLimit / 2, members.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                let batch = db.batch()
                for friendID in chunk {
                    batch.updateData(
                        ["circleID": FriendCircle.defaultID, "updatedAt": FieldValue.serverTimestamp()],
                        forDocument: self.members(hostID).document(friendID)
                    )
                }
                if index == chunks.count - 1 {
                    batch.deleteDocument(self.circles(hostID).document(circleID))
                }
                try await batch.commit()
            }
        }
    }

    func saveMembership(hostID: String, _ membership: CircleMembership, resolvedPolicy: BookingPolicy) async throws {
        guard let friendID = membership.id else { return }
        try await withRetry {
            let batch = db.batch()
            // Written whole, not merged: a cleared override must leave the document, or the
            // resolver keeps preferring it. The membership is three fields the client always holds.
            try batch.setData(from: membership, forDocument: self.members(hostID).document(friendID))
            try batch.setData(
                from: resolvedPolicy,
                forDocument: self.policies(hostID).document(friendID),
                merge: false
            )
            try await batch.commit()
        }
    }

    func publishPolicies(hostID: String, policiesByFriendID: [String: BookingPolicy]) async throws {
        guard !policiesByFriendID.isEmpty else { return }
        let entries = Array(policiesByFriendID)
        try await withRetry {
            for start in stride(from: 0, to: entries.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for (friendID, policy) in entries[start..<min(start + firestoreBatchLimit, entries.count)] {
                    try batch.setData(from: policy, forDocument: self.policies(hostID).document(friendID), merge: false)
                }
                try await batch.commit()
            }
        }
    }

    func seedCircles(hostID: String) async throws {
        try await withRetry {
            let batch = db.batch()
            for circle in FriendCircle.seeded() {
                guard let id = circle.id else { continue }
                // merge:true so a re-run never stomps a renamed or reconfigured circle.
                try batch.setData(from: circle, forDocument: self.circles(hostID).document(id), merge: true)
            }
            try await batch.commit()
        }
    }

    // MARK: - Guest side

    func fetchPolicy(hostID: String, guestID: String) async throws -> BookingPolicy? {
        let snapshot = try await policies(hostID).document(guestID).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: BookingPolicy.self)
    }

    func fetchStayCounter(hostID: String, guestID: String) async throws -> StayCounter? {
        let id = StayCounter.documentID(hostUserID: hostID, guestUserID: guestID)
        let snapshot = try await db.collection(FirestorePaths.stayCounters).document(id).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: StayCounter.self)
    }
}

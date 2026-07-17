//
//  StayRequestsRepository.swift
//  freebnb
//
//  Stay requests: guest/host listeners, sends, and the callable-backed accept.
//  Split out of the former Repositories.swift (A2).
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

// Upper bound for the stay-requests snapshot listener.
private let stayRequestsListenerLimit = 200

protocol StayRequestsRepository: Sendable {
    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener

    func create(_ request: StayRequest) async throws
    /// Rewrites the denormalized `listingHostName` on every request this user
    /// hosts, so a display-name change doesn't leave trip rows showing the old
    /// name forever (L7). Touches only that field.
    func updateListingHostName(hostUserID: String, newName: String) async throws
    /// Moves a request to a new status. Any terminal status also revokes the
    /// guest's access to the listing's exact address.
    /// `cancelledBy` is the caller's own user ID and is required when `status`
    /// is `.cancelled` — the rules pin it to whichever party the transition
    /// belongs to, and the push trigger reads it to notify the other one.
    ///
    /// A decline carries the note of whichever side declined: `hostNote` when the
    /// host turns down a request, `guestNote` when the guest turns down an offer
    /// (feature 43). Passing both, or the wrong one for the caller's role, is
    /// rejected by the rules rather than silently ignored.
    func updateStatus(
        _ request: StayRequest,
        status: StayRequestStatus,
        hostNote: String?,
        guestNote: String?,
        cancelledBy: String?
    ) async throws
    /// Changes the dates on a *pending* request in place (feature 23), instead of
    /// forcing the guest to cancel and re-send. Only the guest may call it, only
    /// while pending, and `firestore.rules` pins every other field so the dates
    /// (and `updatedAt`) are the only things that can move.
    func updateDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws
    /// Closes out an accepted stay that has begun, which is what unlocks both
    /// parties' reviews (feature 4). Either party may call it.
    ///
    /// Deliberately does *not* revoke the address: a guest who taps this on the
    /// first morning of a five-night stay should not lock themselves out of the
    /// street they are standing on. The nightly `expireCompletedStays` sweep
    /// withdraws the grant once checkout has actually passed.
    func markCompleted(_ request: StayRequest) async throws
    /// Accepts a request only if no other already-accepted request for the same
    /// listing overlaps its dates. Throws `StayRequestError.overlappingStay` on
    /// a conflict. A best-effort double-booking guard; authoritative enforcement
    /// still belongs in a server transaction.
    ///
    /// Accepts either direction (feature 43): a host accepting a guest's pending
    /// request, or a guest accepting a host's offer. The callable works out which
    /// from the document and the caller's uid, because the double-booking guard
    /// has to be the same one either way — an offer books the same room.
    ///
    /// Acceptance is also what discloses the exact address, by writing the
    /// `homes/{listingID}/accepted/{guestUserID}` marker the rules check.
    func accept(_ request: StayRequest, hostNote: String?) async throws
}

struct FirestoreStayRequestsRepository: StayRequestsRepository {
    private let db: Firestore
    private let functions: Functions
    init(db: Firestore = .firestore(), functions: Functions = .functions()) {
        self.db = db
        self.functions = functions
    }

    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        let field = role == .guest ? "guestUserID" : "hostUserID"
        let reg = db.collection(FirestorePaths.stayRequests)
            .whereField(field, isEqualTo: userID)
            .order(by: "createdAt", descending: true)
            // Bound the listener; most-recent-first keeps active requests in view.
            .limit(to: stayRequestsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let docs = snapshot?.documents ?? []
                let requests: [StayRequest] = docs.compactMap { doc in
                    do { return try doc.data(as: StayRequest.self) }
                    catch {
                        Telemetry.decodeFailure(collection: FirestorePaths.stayRequests, documentID: doc.documentID, error: error)
                        return nil
                    }
                }
                handler(.success(requests))
            }
        return FirestoreListenerBox(reg)
    }

    func create(_ request: StayRequest) async throws {
        try await withRetry { [db] in
            try db.collection(FirestorePaths.stayRequests).document(request.id).setData(from: request)
        }
    }

    func updateListingHostName(hostUserID: String, newName: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.stayRequests)
                .whereField("hostUserID", isEqualTo: hostUserID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            // Chunk under the 500-op batch cap for hosts with many requests.
            for start in stride(from: 0, to: refs.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for ref in refs[start..<min(start + firestoreBatchLimit, refs.count)] {
                    batch.updateData(["listingHostName": newName], forDocument: ref)
                }
                try await batch.commit()
            }
        }
    }

    private func statusPayload(
        _ status: StayRequestStatus,
        hostNote: String?,
        guestNote: String? = nil,
        cancelledBy: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [
            "status": status.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let hostNote { data["hostNote"] = hostNote }
        // Only ever on a guest's decline of a host's offer (feature 43); every
        // other branch of the rules pins its changed keys, so carrying it
        // elsewhere would be rejected outright.
        if let guestNote { data["guestNote"] = guestNote }
        // Only ever on a cancellation, for the same reason.
        if status == .cancelled, let cancelledBy { data["cancelledBy"] = cancelledBy }
        return data
    }

    func updateStatus(
        _ request: StayRequest,
        status: StayRequestStatus,
        hostNote: String?,
        guestNote: String?,
        cancelledBy: String?
    ) async throws {
        let payload = statusPayload(status, hostNote: hostNote, guestNote: guestNote, cancelledBy: cancelledBy)
        let request = request
        try await withRetry { [db] in
            let batch = db.batch()
            batch.updateData(payload, forDocument: db.collection(FirestorePaths.stayRequests).document(request.id))
            // A declined or cancelled stay must not leave the guest holding the
            // host's street address. Deleting a marker that was never written is
            // a no-op, so this covers requests that never reached `accepted`.
            if !status.isActive {
                batch.deleteDocument(
                    FirestorePaths.acceptedGuest(db, homeID: request.listingID, guestUserID: request.guestUserID)
                )
            }
            try await batch.commit()
        }
    }

    func updateDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws {
        let requestID = request.id
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.stayRequests).document(requestID).updateData([
                "checkIn": Timestamp(date: checkIn),
                "checkOut": Timestamp(date: checkOut),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func markCompleted(_ request: StayRequest) async throws {
        let requestID = request.id
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.stayRequests).document(requestID).updateData([
                "status": StayRequestStatus.completed.rawValue,
                // The rules require both to equal request.time, which is exactly
                // what the server resolves these sentinels to.
                "completedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func accept(_ request: StayRequest, hostNote: String?) async throws {
        // Fast-path UX guard: reject an obvious overlap without a round trip to
        // the function. It is NOT the enforcement point — two devices could both
        // pass it — so the authoritative, atomic check is the acceptStayRequest
        // transaction the callable runs (L1).
        //
        // Host-only, and not merely as an optimization. The rules let a user read
        // a stay request only if they are one of its two parties, so this query —
        // every accepted request for the listing — is rejected outright for a
        // guest accepting an offer (feature 43), taking the whole accept down with
        // it. The guest cannot see the host's other bookings by design, so there
        // is no honest client-side check for them to run; the callable, which
        // reads as admin, is the only thing that can tell them.
        if request.status == .pending {
            let snap = try await db.collection(FirestorePaths.stayRequests)
                .whereField("listingID", isEqualTo: request.listingID)
                .whereField("status", isEqualTo: StayRequestStatus.accepted.rawValue)
                .getDocuments()
            for doc in snap.documents where doc.documentID != request.id {
                guard let other = try? doc.data(as: StayRequest.self) else { continue }
                if other.overlaps(checkIn: request.checkIn, checkOut: request.checkOut) {
                    throw StayRequestError.overlappingStay
                }
            }
        }

        // Authoritative accept: an admin transaction re-checks overlap and writes
        // the status plus the address-disclosure marker atomically. Client rules
        // no longer permit a direct accept, so this callable is the only path.
        var payload: [String: Any] = ["requestID": request.id]
        if let hostNote { payload["hostNote"] = hostNote }
        do {
            _ = try await functions.httpsCallable("acceptStayRequest").call(payload)
        } catch {
            throw Self.mapAcceptError(error)
        }
    }

    /// Surfaces the callable's double-booking rejection ("aborted") as the same
    /// typed error the fast-path guard throws, so the UI shows one message either
    /// way. Other failures pass through unchanged.
    private static func mapAcceptError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain,
           FunctionsErrorCode(rawValue: nsError.code) == .aborted {
            return StayRequestError.overlappingStay
        }
        return error
    }
}

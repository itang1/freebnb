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
    func updateStatus(_ request: StayRequest, status: StayRequestStatus, hostNote: String?) async throws
    /// Accepts a request only if no other already-accepted request for the same
    /// listing overlaps its dates. Throws `StayRequestError.overlappingStay` on
    /// a conflict. A best-effort double-booking guard; authoritative enforcement
    /// still belongs in a server transaction.
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
                        repoLog.error("request decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    private func statusPayload(_ status: StayRequestStatus, hostNote: String?) -> [String: Any] {
        var data: [String: Any] = [
            "status": status.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let hostNote { data["hostNote"] = hostNote }
        return data
    }

    func updateStatus(_ request: StayRequest, status: StayRequestStatus, hostNote: String?) async throws {
        let payload = statusPayload(status, hostNote: hostNote)
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

    func accept(_ request: StayRequest, hostNote: String?) async throws {
        // Fast-path UX guard: reject an obvious overlap without a round trip to
        // the function. The host can read every request to their own listing, so
        // this catches the common conflict instantly. It is NOT the enforcement
        // point — two devices could both pass it — so the authoritative, atomic
        // check is the acceptStayRequest transaction the callable runs (L1).
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

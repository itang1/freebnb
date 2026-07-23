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

/// Firestore caps an `in` filter's value list. Chunked to ten so the query stays
/// legal on every SDK version this app has shipped against, rather than riding
/// the current thirty-value ceiling.
private let listingIDChunkSize = 10

/// Merges the per-chunk co-hosted listeners into one `[StayRequest]` emission.
/// Each chunk reports independently and the newest snapshot of each is kept, so
/// one chunk updating doesn't drop the others.
private final class CoHostedRequestsMerger: @unchecked Sendable {
    private let handler: @Sendable (Result<[StayRequest], Error>) -> Void
    private let chunkCount: Int
    private var chunks: [Int: [StayRequest]] = [:]
    private let lock = NSLock()

    init(chunkCount: Int, handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void) {
        self.chunkCount = chunkCount
        self.handler = handler
    }

    func set(_ requests: [StayRequest], at index: Int) {
        lock.lock()
        chunks[index] = requests
        // Emit as soon as every chunk has reported once; after that, on each
        // update. Waiting for all of them first keeps the host from seeing a
        // half-populated inbox flicker past on launch.
        guard chunks.count == chunkCount else { lock.unlock(); return }
        var seen = Set<String>()
        let merged = chunks.keys.sorted()
            .flatMap { chunks[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
        lock.unlock()
        handler(.success(merged))
    }

    func fail(_ error: Error) { handler(.failure(error)) }
}

protocol StayRequestsRepository: Sendable {
    func listenToRequests(
        userID: String,
        role: StayRequestRole,
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener

    /// Requests aimed at listings this user co-hosts rather than owns (feature 14).
    ///
    /// A stay request names only the listing's owner in `hostUserID`, so the
    /// `role: .host` listener above — which matches on that field — cannot see a
    /// co-host's inbox at all. Co-hosts manage the listing, so they need the same
    /// view of who is asking to stay in it; this is queried by listing instead of
    /// by party, which is the only handle a co-host has on it.
    ///
    /// Returns a listener that emits nothing when `listingIDs` is empty.
    func listenToCoHostedRequests(
        listingIDs: [String],
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

    func listenToCoHostedRequests(
        listingIDs: [String],
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener {
        guard !listingIDs.isEmpty else { return CompositeListener(listeners: []) }

        let chunks = stride(from: 0, to: listingIDs.count, by: listingIDChunkSize).map {
            Array(listingIDs[$0..<min($0 + listingIDChunkSize, listingIDs.count)])
        }
        let merger = CoHostedRequestsMerger(chunkCount: chunks.count, handler: handler)

        let registrations = chunks.enumerated().map { index, chunk in
            let reg = db.collection(FirestorePaths.stayRequests)
                .whereField("listingID", in: chunk)
                .order(by: "createdAt", descending: true)
                .limit(to: stayRequestsListenerLimit)
                .addSnapshotListener { snapshot, error in
                    if let error { merger.fail(error); return }
                    let requests: [StayRequest] = (snapshot?.documents ?? []).compactMap { doc in
                        do { return try doc.data(as: StayRequest.self) }
                        catch {
                            Telemetry.decodeFailure(collection: FirestorePaths.stayRequests, documentID: doc.documentID, error: error)
                            return nil
                        }
                    }
                    merger.set(requests, at: index)
                }
            return FirestoreListenerBox(reg) as RepositoryListener
        }
        return CompositeListener(listeners: registrations)
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

    /// Accepts a pending request from the host's side, without the callable.
    ///
    /// The double-booking guard is a transaction over the listing document. A
    /// client transaction cannot read a *query* — which is why acceptance was a
    /// callable in the first place — but it can read a document, and the listing
    /// already carries `unavailableDateRanges`, the merged calendar guests read.
    /// Two devices accepting at once both read that field and both try to write
    /// it, so Firestore serializes them: the second retries against the first's
    /// result and sees the overlap.
    ///
    /// Only `pending`, and only the host side. An offer is the guest's to accept
    /// and stays on the callable: the guest may not read this listing's calendar,
    /// and the address grant below is not theirs to write.
    private func acceptAsHost(_ request: StayRequest, hostNote: String?) async throws {
        let requestRef = db.collection(FirestorePaths.stayRequests).document(request.id)
        let listingRef = db.collection(FirestorePaths.homes).document(request.listingID)
        let markerRef = listingRef
            .collection(FirestorePaths.accepted)
            .document(request.guestUserID)

        try await db.runTransaction { transaction, errorPointer -> Any? in
            let reqSnap: DocumentSnapshot
            let listingSnap: DocumentSnapshot
            do {
                reqSnap = try transaction.getDocument(requestRef)
                listingSnap = try transaction.getDocument(listingRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }

            // Re-read rather than trust the row that was tapped: it may have been
            // cancelled, or already accepted on another device, since it rendered.
            guard let current = try? reqSnap.data(as: StayRequest.self),
                  current.status == .pending else {
                errorPointer?.pointee = StayRequestError.noLongerPending as NSError
                return nil
            }
            guard let listing = try? listingSnap.data(as: Home.self),
                  listing.deletedAt == nil else {
                errorPointer?.pointee = StayRequestError.listingUnavailable as NSError
                return nil
            }

            let taken = listing.unavailableRanges
            if taken.contains(where: { $0.overlaps(checkIn: current.checkIn, checkOut: current.checkOut) }) {
                errorPointer?.pointee = StayRequestError.overlappingStay as NSError
                return nil
            }

            let booked = DateRange(start: current.checkIn, end: current.checkOut)
            var updatedRanges = listing.unavailableDateRanges ?? []
            updatedRanges.append(booked)

            var fields: [String: Any] = [
                "status": StayRequestStatus.accepted.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let hostNote { fields["hostNote"] = hostNote }
            transaction.updateData(fields, forDocument: requestRef)

            // The write that makes the read above binding. Also what a guest sees:
            // the dates go unavailable the moment the stay is confirmed.
            transaction.updateData(
                ["unavailableDateRanges": updatedRanges.map { ["start": $0.start, "end": $0.end] }],
                forDocument: listingRef
            )

            // The address grant, in the same commit as the acceptance, which is the
            // property the rules check with getAfter().
            transaction.setData(
                [
                    "requestID": request.id,
                    "guestUserID": request.guestUserID,
                    "createdAt": FieldValue.serverTimestamp()
                ],
                forDocument: markerRef
            )
            return nil
        }
    }

    func accept(_ request: StayRequest, hostNote: String?) async throws {
        // No client-side overlap pre-check, because the rules cannot admit one:
        // they allow a stay-request read only to the document's own two parties,
        // and a `list` is evaluated against its potential result set, so a query
        // for every accepted request on a listing is denied for the host as well
        // as the guest. Only the callable, reading as admin, can see the other
        // bookings; it returns `aborted` on a double-booking, which
        // `mapAcceptError` maps to `overlappingStay`.

        // A pending request is the host's to answer, and that path no longer needs
        // a server: `acceptAsHost` serializes on the listing document. An offer is
        // the guest's to answer and still does need one — they cannot read the
        // calendar to check overlap, and cannot write themselves the address.
        if request.status == .pending {
            try await acceptAsHost(request, hostNote: hostNote)
            return
        }

        // Authoritative accept for an offer: an admin transaction re-checks
        // overlap and writes the status plus the address-disclosure marker
        // atomically. Undeployed in production, where accepting an offer therefore
        // still fails — the guest-side gap this change does not close.
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

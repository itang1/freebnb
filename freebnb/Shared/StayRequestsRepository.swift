//
//  StayRequestsRepository.swift
//  freebnb
//
//  Stay requests: guest/host listeners, sends, and the callable-backed accept.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

// Upper bound for the stay-requests snapshot listener.
private let stayRequestsListenerLimit = 200

/// Firestore caps an `in` filter's value list; chunked to ten to stay legal on every SDK version.
private let listingIDChunkSize = 10

/// Merges the per-chunk co-hosted listeners into one `[StayRequest]` emission,
/// keeping each chunk's newest snapshot.
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
        // Emit once every chunk has reported, then on each update, so the inbox doesn't flicker half-populated.
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

    /// Requests aimed at listings this user co-hosts rather than owns. Queried by
    /// listing, since requests name only the owner in `hostUserID`. Emits nothing
    /// when `listingIDs` is empty.
    func listenToCoHostedRequests(
        listingIDs: [String],
        handler: @escaping @Sendable (Result<[StayRequest], Error>) -> Void
    ) -> RepositoryListener

    /// Creates the request and, when the host's circle policy caps this guest's
    /// bookings, advances their `stayCounters` document in the same commit; the
    /// rules read it with `getAfter()`. Nil means uncapped.
    func create(_ request: StayRequest, advancing counter: StayCounter?) async throws
    /// Rewrites the denormalized `listingHostName` on every request this user hosts.
    func updateListingHostName(hostUserID: String, newName: String) async throws
    /// Moves a request to a new status; terminal statuses revoke the guest's
    /// address access. `cancelledBy` is required for `.cancelled` (the rules pin
    /// it and the push trigger reads it). A decline carries the declining side's
    /// note (`hostNote` or `guestNote`); the wrong one is rejected by the rules.
    func updateStatus(
        _ request: StayRequest,
        status: StayRequestStatus,
        hostNote: String?,
        guestNote: String?,
        cancelledBy: String?
    ) async throws
    /// Changes the dates on a pending request in place; guest only, and the
    /// rules pin every other field.
    func updateDates(_ request: StayRequest, checkIn: Date, checkOut: Date) async throws
    /// Closes out an accepted stay that has begun, unlocking reviews. Either party
    /// may call it. It keeps the address grant; the nightly `expireCompletedStays`
    /// sweep withdraws it after checkout.
    func markCompleted(_ request: StayRequest) async throws
    /// Accepts a request only if no other accepted request for the listing
    /// overlaps its dates (throws `StayRequestError.overlappingStay`). Handles a
    /// host accepting a request or a guest accepting an offer, and writes the
    /// `homes/{listingID}/accepted/{guestUserID}` marker that discloses the address.
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

    func create(_ request: StayRequest, advancing counter: StayCounter?) async throws {
        try await withRetry { [db] in
            guard let counter else {
                try db.collection(FirestorePaths.stayRequests).document(request.id).setData(from: request)
                return
            }
            // One batch: a request without its counter advance is rejected, and an advance without its
            // request wastes a slot.
            let batch = db.batch()
            try batch.setData(
                from: request,
                forDocument: db.collection(FirestorePaths.stayRequests).document(request.id)
            )
            try batch.setData(
                from: counter,
                forDocument: db.collection(FirestorePaths.stayCounters).document(
                    StayCounter.documentID(hostUserID: counter.hostUserID, guestUserID: counter.guestUserID)
                )
            )
            try await batch.commit()
        }
    }

    func updateListingHostName(hostUserID: String, newName: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.stayRequests)
                .whereField("hostUserID", isEqualTo: hostUserID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            // Chunked under the 500-op batch cap.
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
        // Only on a guest's decline of an offer; other rule branches pin their keys.
        if let guestNote { data["guestNote"] = guestNote }
        // Only on a cancellation, for the same reason.
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
            // Declined or cancelled stays must not leave the guest the address; deleting a missing marker is
            // a no-op.
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
                // The rules require these to equal request.time, which the server sentinels resolve to.
                "completedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    /// Accepts a pending request from the host's side, without the callable. A
    /// transaction over the listing document serializes concurrent accepts: both
    /// read and write `unavailableDateRanges`, so the second retries and sees the
    /// overlap. Pending only; offers take `acceptAsGuest`.
    private func acceptAsHost(_ request: StayRequest, hostNote: String?) async throws {
        let requestRef = db.collection(FirestorePaths.stayRequests).document(request.id)
        let listingRef = db.collection(FirestorePaths.homes).document(request.listingID)
        let availabilityRef = FirestorePaths.listingAvailability(db, homeID: request.listingID)
        let markerRef = listingRef
            .collection(FirestorePaths.accepted)
            .document(request.guestUserID)

        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            let reqSnap: DocumentSnapshot
            let listingSnap: DocumentSnapshot
            // The host's turnover buffer, read in the same transaction (managers only,
            // so `acceptAsGuest` can't).
            let availabilitySnap: DocumentSnapshot
            do {
                reqSnap = try transaction.getDocument(requestRef)
                listingSnap = try transaction.getDocument(listingRef)
                availabilitySnap = try transaction.getDocument(availabilityRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }

            // Re-read: the row may have been cancelled or accepted elsewhere since it rendered.
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

            // Pad the booking with the host's buffer so the surrounding days close in
            // the same write; the reconciler recomputes the same set. A missing
            // availability doc falls back to the default buffer.
            let bufferHours = (try? availabilitySnap.data(as: ListingAvailability.self))?.bufferHours
                ?? ListingAvailability.defaultBufferHours
            let bookedFootprint = AvailabilityCalendar.buffered(
                [DateRange(start: current.checkIn, end: current.checkOut)],
                bufferHours: bufferHours
            )
            var updatedRanges = listing.unavailableDateRanges ?? []
            updatedRanges.append(contentsOf: bookedFootprint)

            var fields: [String: Any] = [
                "status": StayRequestStatus.accepted.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let hostNote { fields["hostNote"] = hostNote }
            transaction.updateData(fields, forDocument: requestRef)

            // The write that makes the read binding; also what the guest sees.
            transaction.updateData(
                ["unavailableDateRanges": updatedRanges.map { ["start": $0.start, "end": $0.end] }],
                forDocument: listingRef
            )

            // The address grant, in the same commit (the rules check it with getAfter()).
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

    /// Accepts a host's offer from the guest's side. Guests can't read the
    /// managers-only calendar, so there's no serialized overlap check; it checks
    /// the public ranges, then writes the status and the guest's address grant.
    /// The host's reconciler records the booking and is the real double-booking guard.
    private func acceptAsGuest(_ request: StayRequest) async throws {
        let requestRef = db.collection(FirestorePaths.stayRequests).document(request.id)
        let listingRef = db.collection(FirestorePaths.homes).document(request.listingID)
        let markerRef = listingRef
            .collection(FirestorePaths.accepted)
            .document(request.guestUserID)

        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            let reqSnap: DocumentSnapshot
            let listingSnap: DocumentSnapshot
            do {
                reqSnap = try transaction.getDocument(requestRef)
                listingSnap = try transaction.getDocument(listingRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }

            guard let current = try? reqSnap.data(as: StayRequest.self),
                  current.status == .offered else {
                errorPointer?.pointee = StayRequestError.noLongerPending as NSError
                return nil
            }
            guard let listing = try? listingSnap.data(as: Home.self),
                  listing.deletedAt == nil else {
                errorPointer?.pointee = StayRequestError.listingUnavailable as NSError
                return nil
            }

            // Advisory: catches dates the host has since filled but can't serialize
            // against a concurrent accept; the reconciler closes that.
            let taken = listing.unavailableRanges
            if taken.contains(where: { $0.overlaps(checkIn: current.checkIn, checkOut: current.checkOut) }) {
                errorPointer?.pointee = StayRequestError.overlappingStay as NSError
                return nil
            }

            transaction.updateData(
                [
                    "status": StayRequestStatus.accepted.rawValue,
                    "updatedAt": FieldValue.serverTimestamp()
                ],
                forDocument: requestRef
            )
            // The guest's own address grant, in the same commit (the getAfter correlation).
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
        // A pending request is the host's and serializes on the listing document; an
        // offer is the guest's and checks advisorily, deferring to the host's reconciler.
        if request.status == .offered {
            try await acceptAsGuest(request)
        } else {
            try await acceptAsHost(request, hostNote: hostNote)
        }
    }

    /// Maps the callable's "aborted" double-booking rejection to the typed error
    /// the fast-path guard throws. Kept for any residual callable path.
    private static func mapAcceptError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain,
           FunctionsErrorCode(rawValue: nsError.code) == .aborted {
            return StayRequestError.overlappingStay
        }
        return error
    }
}

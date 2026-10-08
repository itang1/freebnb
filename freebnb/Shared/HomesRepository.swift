//
//  HomesRepository.swift
//  freebnb
//
//  The listings repository: visible-listings feed, own-listings snapshot, writes,
//  and the address-disclosure ref builders.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

// Upper bound for the own-listings listener, so a prolific host doesn't download an unbounded collection.
private let ownListingsListenerLimit = 200

protocol HomesRepository: Sendable {
    /// Listens to the listings `viewerID` may read; see `FirestoreHomesRepository` for why it isn't one query.
    func listenToVisibleListings(
        viewerID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    /// Listings the user hosts or co-hosts.
    func listenToManagedListings(
        userID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    /// One-shot cursor page of visible listings after `cursor`, in recency order.
    func fetchVisibleListings(viewerID: String, after cursor: ListingCursor?, limit: Int) async throws -> [Home]

    func save(_ home: Home) async throws
    func delete(homeID: String) async throws
    func updateHostName(userID: String, newName: String) async throws
    func softDeleteAllListings(hostUserID: String) async throws

    /// The street address and exact coordinates. Throws `permissionDenied` unless
    /// the caller is the host or an accepted guest; nil for listings that predate the split.
    func fetchLocation(homeID: String) async throws -> ListingLocation?
    func saveLocation(homeID: String, location: ListingLocation) async throws
    /// The house manual, gated like the location. Nil when not entitled or unwritten.
    func fetchManual(homeID: String) async throws -> HouseManual?
    func saveManual(homeID: String, manual: HouseManual) async throws
    /// The unmerged calendar, for managers only (guests get just the merged
    /// `Home.unavailableDateRanges`). Throws `permissionDenied` otherwise; empty if nothing is closed.
    func fetchAvailability(homeID: String) async throws -> ListingAvailability
    /// Writes the host-authored blocked half.
    func saveBlockedRanges(homeID: String, blocked: [DateRange]) async throws
    /// Writes the booked half, authored by the host's reconciler from accepted stays.
    func saveBookedRanges(homeID: String, booked: [DateRange]) async throws
    /// Writes the turnover buffer in hours, as a merge on that one field.
    func saveBufferHours(homeID: String, bufferHours: Int) async throws
}

/// The feed's canonical order: newest first, document id descending as the
/// tiebreak. Matches both feed queries' `(createdAt DESC, documentID DESC)`.
/// A listing without `createdAt` sorts last.
func recencyOrdered(_ homes: [Home]) -> [Home] {
    homes.sorted { a, b in
        let aDate = a.createdAt ?? .distantPast
        let bDate = b.createdAt ?? .distantPast
        if aDate != bDate { return aDate > bDate }
        return a.id > b.id
    }
}

/// Pagination boundary: the `(createdAt, id)` of the last listing shown. Both
/// are needed, since `createdAt` alone could skip or duplicate ties.
struct ListingCursor: Sendable {
    let createdAt: Date
    let id: String
}

/// Joins the hosted and co-hosted halves of the managed-listings query into one
/// de-duplicated list. Snapshots arrive on the main queue, so state is accessed
/// serially. Emits only once both halves have arrived, to avoid inserting
/// co-hosted rows under the reader's thumb.
private final class ManagedListingsMerger: @unchecked Sendable {
    private let handler: @Sendable (Result<[Home], Error>) -> Void
    private var hosted: [Home]?
    private var coHosted: [Home]?

    init(handler: @escaping @Sendable (Result<[Home], Error>) -> Void) {
        self.handler = handler
    }

    func setHosted(_ homes: [Home]) { hosted = homes; emit() }
    func setCoHosted(_ homes: [Home]) { coHosted = homes; emit() }
    func fail(_ error: Error) { handler(.failure(error)) }

    /// A listing can't be in both halves (the rules forbid a host co-hosting their own), but de-duping is free.
    private func emit() {
        guard let hosted, let coHosted else { return }
        var seen = Set<String>()
        let merged = (hosted + coHosted).filter { seen.insert($0.id).inserted }
        handler(.success(merged))
    }
}

struct FirestoreHomesRepository: HomesRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func decode(_ documents: [QueryDocumentSnapshot], context: StaticString) -> [Home] {
        documents.compactMap { doc in
            do { return try doc.data(as: Home.self) }
            catch {
                // Count dropped documents so a corrupt listing shows up as a decode-failure rate (query
                // context in the id field).
                Telemetry.decodeFailure(collection: FirestorePaths.homes, documentID: "\(context)/\(doc.documentID)", error: error)
                return nil
            }
        }
    }

    // Firestore rejects a whole query if any matched document fails the read
    // rule, so the feed can't be an unfiltered `homes` query. `allowedViewerIDs
    // arrayContains me` is provably safe to the rules engine and also covers the
    // viewer's own listings. Order is createdAt DESC with documentID DESC as a
    // same-direction tiebreak, so one composite index serves cursor pagination.
    private func allowedQuery(viewerID: String) -> Query {
        db.collection(FirestorePaths.homes)
            .whereField("allowedViewerIDs", arrayContains: viewerID)
            .order(by: "createdAt", descending: true)
            .order(by: FieldPath.documentID(), descending: true)
    }

    func listenToVisibleListings(
        viewerID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        // A signed-out viewer is in nobody's ACL; skip a query that can only return nothing.
        guard !viewerID.isEmpty else {
            handler(.success([]))
            return NoopListener()
        }

        // No cached-empty gating: an empty feed is legitimate for a viewer with no friends, and waiting would
        // hang offline.
        let allowedReg = allowedQuery(viewerID: viewerID)
            .limit(to: limit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                handler(.success(decode(snapshot?.documents ?? [], context: "feed")))
            }

        return FirestoreListenerBox(allowedReg)
    }

    /// Firestore has no OR across two fields, so this is two single-field
    /// queries merged client-side; neither needs a composite index.
    func listenToManagedListings(
        userID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let merger = ManagedListingsMerger(handler: handler)

        // Bound both listeners so a prolific host doesn't download an unbounded collection.
        let hostedReg = db.collection(FirestorePaths.homes)
            .whereField("hostUserID", isEqualTo: userID)
            .limit(to: ownListingsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { merger.fail(error); return }
                merger.setHosted(decode(snapshot?.documents ?? [], context: "own"))
            }

        let coHostedReg = db.collection(FirestorePaths.homes)
            .whereField("coHostUserIDs", arrayContains: userID)
            .limit(to: ownListingsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { merger.fail(error); return }
                merger.setCoHosted(decode(snapshot?.documents ?? [], context: "cohosted"))
            }

        return CompositeListener(listeners: [
            FirestoreListenerBox(hostedReg),
            FirestoreListenerBox(coHostedReg)
        ])
    }

    func fetchVisibleListings(viewerID: String, after cursor: ListingCursor?, limit: Int) async throws -> [Home] {
        guard !viewerID.isEmpty else { return [] }
        return try await withRetry {
            var query = allowedQuery(viewerID: viewerID).limit(to: limit)
            // Cursor values must line up with the order-by fields.
            if let cursor {
                query = query.start(after: [Timestamp(date: cursor.createdAt), cursor.id])
            }
            return decode(try await query.getDocuments().documents, context: "page")
        }
    }

    func save(_ home: Home) async throws {
        try await withRetry { [db] in
            var data = try Firestore.Encoder().encode(home)
            // A new listing gets the server timestamp (the rules require it equal request.time); edits keep
            // the existing value.
            if home.createdAt == nil {
                data["createdAt"] = FieldValue.serverTimestamp()
            }
            try await db.collection(FirestorePaths.homes).document(home.id).setData(data)
        }
    }

    func delete(homeID: String) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.homes).document(homeID).updateData([
                "deletedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    /// Pages through every listing hosted by `hostUserID` in document-id order,
    /// applying `mutate` to each page in its own retried batch, so a transient
    /// failure resumes at the current page. Callers' writes are idempotent. The
    /// equality filter plus `__name__` order needs no composite index, and since
    /// neither caller touches `hostUserID` the id cursor advances without skips.
    private func forEachHostListingPage(
        hostUserID: String,
        fields: @Sendable @escaping () -> [String: Any]
    ) async throws {
        var cursor: DocumentSnapshot?
        while true {
            let startAfter = cursor
            let snapshot = try await withRetry { [db] in
                var query = db.collection(FirestorePaths.homes)
                    .whereField("hostUserID", isEqualTo: hostUserID)
                    .order(by: FieldPath.documentID())
                    .limit(to: firestoreBatchLimit)
                if let startAfter { query = query.start(afterDocument: startAfter) }
                return try await query.getDocuments()
            }
            let documents = snapshot.documents
            guard !documents.isEmpty else { return }
            try await commitPage(documents, fields: fields)
            // A short final page means the host's listings are drained.
            if documents.count < firestoreBatchLimit { return }
            cursor = documents.last
        }
    }

    /// Applies `fields` to one page of listings. A batch is atomic and the
    /// `homes` update rule re-validates the whole merged document, so one stale
    /// listing (from before `scripts/migrate_friends_only.js`) would fail the
    /// commit for every healthy one. A failed batch is therefore retried document
    /// by document, recording each refusal. Only a page refused in its entirety
    /// rethrows, since that means something systemic (signed out, rules withdrawn).
    private func commitPage(
        _ documents: [QueryDocumentSnapshot],
        fields: @Sendable @escaping () -> [String: Any]
    ) async throws {
        do {
            try await withRetry { [db] in
                let batch = db.batch()
                for document in documents {
                    batch.updateData(fields(), forDocument: document.reference)
                }
                try await batch.commit()
            }
            return
        } catch {
            // Fall through to find which documents the server refused.
        }

        var failures: [Error] = []
        for document in documents {
            let reference = document.reference
            do {
                try await withRetry { try await reference.updateData(fields()) }
            } catch {
                failures.append(error)
                Telemetry.recordError(error, context: "listing fan-out \(document.documentID)")
            }
        }
        if failures.count == documents.count, let first = failures.first { throw first }
    }

    func updateHostName(userID: String, newName: String) async throws {
        try await forEachHostListingPage(hostUserID: userID) { ["hostName": newName] }
    }

    func softDeleteAllListings(hostUserID: String) async throws {
        // The server's clock, not the device's, matching `delete(homeID:)`; the rules
        // only check `deletedAt` is a timestamp, so a skewed device could back-date it.
        try await forEachHostListingPage(hostUserID: hostUserID) {
            ["deletedAt": FieldValue.serverTimestamp()]
        }
    }

    func fetchLocation(homeID: String) async throws -> ListingLocation? {
        try await withRetry { [db] in
            let snap = try await FirestorePaths.listingLocation(db, homeID: homeID).getDocument()
            guard snap.exists else { return nil }
            return try snap.data(as: ListingLocation.self)
        }
    }

    func saveLocation(homeID: String, location: ListingLocation) async throws {
        try await withRetry { [db] in
            try FirestorePaths.listingLocation(db, homeID: homeID).setData(from: location)
        }
    }

    func fetchManual(homeID: String) async throws -> HouseManual? {
        try await withRetry { [db] in
            let snap = try await FirestorePaths.listingManual(db, homeID: homeID).getDocument()
            guard snap.exists else { return nil }
            return try snap.data(as: HouseManual.self)
        }
    }

    func saveManual(homeID: String, manual: HouseManual) async throws {
        try await withRetry { [db] in
            try FirestorePaths.listingManual(db, homeID: homeID).setData(from: manual)
        }
    }

    func fetchAvailability(homeID: String) async throws -> ListingAvailability {
        try await withRetry { [db] in
            let snap = try await FirestorePaths.listingAvailability(db, homeID: homeID).getDocument()
            guard snap.exists else { return ListingAvailability() }
            return try snap.data(as: ListingAvailability.self)
        }
    }

    /// Writes the host's half as a merge on that one field; a whole-document
    /// write would clobber or be rejected for `bookedDateRanges`, which is server-owned.
    func saveBlockedRanges(homeID: String, blocked: [DateRange]) async throws {
        try await withRetry { [db] in
            let encoded = try blocked.map { try Firestore.Encoder().encode($0) }
            try await FirestorePaths.listingAvailability(db, homeID: homeID)
                .setData(["blockedDateRanges": encoded], merge: true)
        }
    }

    func saveBookedRanges(homeID: String, booked: [DateRange]) async throws {
        try await withRetry { [db] in
            let encoded = try booked.map { try Firestore.Encoder().encode($0) }
            try await FirestorePaths.listingAvailability(db, homeID: homeID)
                .setData(["bookedDateRanges": encoded], merge: true)
        }
    }

    /// The same one-field merge; the rules validate `bufferHours` as an optional int.
    func saveBufferHours(homeID: String, bufferHours: Int) async throws {
        try await withRetry { [db] in
            try await FirestorePaths.listingAvailability(db, homeID: homeID)
                .setData(["bufferHours": bufferHours], merge: true)
        }
    }
}

/// The subcollection paths behind progressive address disclosure. The app and
/// `firestore.rules` both depend on these exact names; a typo hides addresses silently.
extension FirestorePaths {
    static func listingLocation(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.locationDocID)
    }

    /// The private house manual, gated like the location document.
    static func listingManual(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.manualDocID)
    }

    /// The unmerged calendar. Stricter than `location` and `manual`: it never
    /// opens to a guest, whose only view is the merged public copy.
    static func listingAvailability(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.availabilityDocID)
    }

    /// Marker whose existence grants `guestUserID` read access to the private location; written on accept.
    static func acceptedGuest(_ db: Firestore, homeID: String, guestUserID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.accepted).document(guestUserID)
    }
}

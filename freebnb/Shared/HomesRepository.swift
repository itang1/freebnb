//
//  HomesRepository.swift
//  freebnb
//
//  The listings repository: the paginated visible-listings feed, own-listings
//  snapshot, writes, and the progressive address-disclosure ref builders.
//  Split out of the former Repositories.swift (A2).
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

// Upper bound for the own-listings snapshot listener so a prolific host
// doesn't download an ever-growing collection on every launch.
private let ownListingsListenerLimit = 200

protocol HomesRepository: Sendable {
    /// Listens to the listings `viewerID` is allowed to read. See
    /// `FirestoreHomesRepository` for why this cannot be one query.
    func listenToVisibleListings(
        viewerID: String,
        limit: Int,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    /// Listings the user may manage: the ones they host, and the ones they
    /// co-host (feature 14).
    func listenToManagedListings(
        userID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener

    /// One-shot cursor page of visible listings after `cursor` (recency order).
    /// Used to fetch older pages without re-downloading earlier ones.
    func fetchVisibleListings(viewerID: String, after cursor: ListingCursor?, limit: Int) async throws -> [Home]

    func save(_ home: Home) async throws
    func delete(homeID: String) async throws
    func updateHostName(userID: String, newName: String) async throws
    func softDeleteAllListings(hostUserID: String) async throws

    /// The listing's street address and exact coordinates. Throws
    /// `permissionDenied` when the caller is neither the host nor a guest with an
    /// accepted stay; returns nil when the listing predates the private-location
    /// split and has no such document.
    func fetchLocation(homeID: String) async throws -> ListingLocation?
    func saveLocation(homeID: String, location: ListingLocation) async throws
    /// The host-authored house manual, gated by the same accepted-guest rule as
    /// the location. Returns nil when the caller isn't entitled to it or none
    /// has been written.
    func fetchManual(homeID: String) async throws -> HouseManual?
    func saveManual(homeID: String, manual: HouseManual) async throws
    /// The listing's calendar with blocked and booked still apart, for the people
    /// who manage it. Throws `permissionDenied` for anyone else, guests included:
    /// the merged `Home.unavailableDateRanges` is all a guest ever gets. Returns
    /// an empty value when no day has been closed or booked yet.
    func fetchAvailability(homeID: String) async throws -> ListingAvailability
    /// Writes the host-authored blocked half.
    func saveBlockedRanges(homeID: String, blocked: [DateRange]) async throws
    /// Writes the booked half. Authored by the host's reconciler now, not a
    /// trigger, from the listing's accepted stays.
    func saveBookedRanges(homeID: String, booked: [DateRange]) async throws
    /// Writes the host's turnover buffer, in hours. A merge write on the one
    /// field, so it rides alongside the blocked and booked halves without
    /// touching them.
    func saveBufferHours(homeID: String, bufferHours: Int) async throws
}

/// The feed's canonical order: newest first, with document id descending as a
/// total-order tiebreak for listings sharing a `createdAt`. Matches the
/// `(createdAt DESC, documentID DESC)` order-by both feed queries use, so
/// client-side merges and the in-memory double page identically to Firestore.
/// A listing with no `createdAt` (pre-backfill legacy) sorts last; the ordered
/// query excludes it entirely, so it should never reach here in practice.
func recencyOrdered(_ homes: [Home]) -> [Home] {
    homes.sorted { a, b in
        let aDate = a.createdAt ?? .distantPast
        let bDate = b.createdAt ?? .distantPast
        if aDate != bDate { return aDate > bDate }
        return a.id > b.id
    }
}

/// Pagination boundary for the recency feed: the `(createdAt, id)` of the last
/// listing already shown. Both fields are needed because the queries order by
/// `(createdAt DESC, documentID DESC)`; a cursor on `createdAt` alone could skip
/// or duplicate listings that share a timestamp.
struct ListingCursor: Sendable {
    let createdAt: Date
    let id: String
}

/// Joins the hosted and co-hosted halves of the managed-listings query into one
/// de-duplicated list (feature 14). Firestore delivers snapshot callbacks on the
/// main queue by default, so the mutable state is accessed serially.
///
/// Emits only once both halves have arrived. A user with no co-hosted listings
/// still gets an (empty) snapshot for that half promptly, so this costs nothing;
/// emitting early would flash "Your Listings" without its co-hosted rows and then
/// insert them under the reader's thumb.
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

    /// A listing cannot be in both halves — the rules refuse a host who is their
    /// own co-host — but de-duplicating by id costs nothing and means a future
    /// relaxation of that rule can't produce a duplicated row.
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
                // Count the dropped document so a corrupt listing surfaces as a
                // decode-failure rate instead of vanishing silently (A5). The
                // query context (feed/own/page) rides along in the id field.
                Telemetry.decodeFailure(collection: FirestorePaths.homes, documentID: "\(context)/\(doc.documentID)", error: error)
                return nil
            }
        }
    }

    // Firestore rejects an entire query if any matched document fails the read
    // rule, so the feed cannot be an unfiltered `homes` query. Listings are
    // friends-only, and `allowedViewerIDs arrayContains me` is the one clause of
    // the read rule that is provably safe to the rules engine — it also covers
    // the viewer's own listings, since the ACL always names the host.
    // Recency order (createdAt DESC), with documentID DESC as a same-direction
    // tiebreak so a single composite index (its implicit __name__ DESC) serves
    // the whole order and cursor pagination has a total order to page against.
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
        // A signed-out viewer is in nobody's ACL; report the empty feed rather
        // than issuing a query that can only ever return nothing.
        guard !viewerID.isEmpty else {
            handler(.success([]))
            return NoopListener()
        }

        // No cached-empty-snapshot gating here: an empty feed is legitimate for
        // a viewer with no friends, and waiting on a server snapshot for it
        // would hang the feed offline.
        let allowedReg = allowedQuery(viewerID: viewerID)
            .limit(to: limit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                handler(.success(decode(snapshot?.documents ?? [], context: "feed")))
            }

        return FirestoreListenerBox(allowedReg)
    }

    /// Firestore has no OR across two fields, so this is two queries merged
    /// client-side — the same partition trick the feed uses. Both are
    /// single-field (an equality, then an array-contains), so neither needs a
    /// composite index.
    func listenToManagedListings(
        userID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let merger = ManagedListingsMerger(handler: handler)

        // Bound both listeners so a prolific host doesn't download an
        // ever-growing collection on every launch.
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
            // Cursor values must line up with the order-by fields:
            // createdAt (as a Timestamp) then the document id.
            if let cursor {
                query = query.start(after: [Timestamp(date: cursor.createdAt), cursor.id])
            }
            return decode(try await query.getDocuments().documents, context: "page")
        }
    }

    func save(_ home: Home) async throws {
        try await withRetry { [db] in
            var data = try Firestore.Encoder().encode(home)
            // A new listing gets the server timestamp the feed orders by; the
            // rules require createdAt to equal request.time on create. An edit
            // carries the existing (non-nil) value through unchanged.
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
    /// applying `mutate` to each page in its own retried batch. Paging bounds
    /// memory no matter how prolific the host, and because each page's read and
    /// commit is its own `withRetry` scope, a transient failure resumes at the
    /// current page rather than restarting the whole scan (A9). Both callers'
    /// writes are idempotent, so re-committing a page after a retry is safe.
    /// The equality filter plus an order-by on `__name__` is served by the
    /// automatic single-field index, so this needs no composite index; and
    /// because neither caller touches `hostUserID`, mutated docs keep matching
    /// and the id cursor advances monotonically without skips or loops.
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

    /// Applies `fields` to one page of listings.
    ///
    /// The batch is the fast path: one round trip for the whole page. But a batch
    /// is atomic, and the `homes` update rule re-validates the *entire* merged
    /// document — so one listing that predates `scripts/migrate_friends_only.js`
    /// (still carrying `visibility`, or missing a key the validator now requires)
    /// fails the commit for every healthy listing sitting beside it in the batch.
    /// A host with a single stale listing could not rename themselves at all, and
    /// the rename surfaced as an outright failure rather than as the one document
    /// that refused.
    ///
    /// So a failed batch is retried document by document: everything that can
    /// move does, and each refusal is recorded individually. Only a page that
    /// refused *in its entirety* rethrows, because that means something systemic
    /// (signed out, rules withdrawn) rather than one document left behind by a
    /// migration.
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
            // Fall through: find out which of these the server actually refused.
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
        // The server's clock, not the device's. `isValidListing` only checks that
        // `deletedAt` is a timestamp, so a client-supplied one is accepted as
        // written and a skewed device could back- or forward-date its own soft
        // delete. `delete(homeID:)` already stamps the server time; these two
        // describe the same event and should agree on who timestamps it.
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

    /// Writes the host's half and leaves the server's half alone. A merge write on
    /// the one field, not `setData(from:)`, because the document also carries
    /// `bookedDateRanges`, which the rules pin as server-owned — a whole-document
    /// write would either clobber a booking or be rejected outright.
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

    /// The same one-field merge as the two halves above: the rules validate
    /// `bufferHours` as an optional int on this managers-only document, so the
    /// write neither clobbers the calendar nor needs the whole document present.
    func saveBufferHours(homeID: String, bufferHours: Int) async throws {
        try await withRetry { [db] in
            try await FirestorePaths.listingAvailability(db, homeID: homeID)
                .setData(["bufferHours": bufferHours], merge: true)
        }
    }
}

/// The two subcollection paths that implement progressive address disclosure.
/// Both the app and `firestore.rules` depend on these exact names; a typo here
/// silently hides addresses rather than failing loudly.
extension FirestorePaths {
    static func listingLocation(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.locationDocID)
    }

    /// The listing's private house manual, sharing the accepted-guest visibility
    /// gate with the location document.
    static func listingManual(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.manualDocID)
    }

    /// The listing's calendar in its unmerged form. Gated harder than the two
    /// above: `location` and `manual` open up to an accepted guest, this one never
    /// does, because the merged copy on the public document is the only version of
    /// availability a guest is ever meant to hold.
    static func listingAvailability(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.availabilityDocID)
    }

    /// Marker document whose mere existence grants `guestUserID` read access to
    /// the listing's private location. Written when the host accepts a stay.
    static func acceptedGuest(_ db: Firestore, homeID: String, guestUserID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.accepted).document(guestUserID)
    }
}

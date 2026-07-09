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

    func listenToOwnListings(
        hostUserID: String,
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

/// De-duplicates and orders the results of the visibility-partitioned queries,
/// truncating to the caller's page size. Because both underlying queries return
/// results already in `recencyOrdered` order, taking the first `limit` of the
/// merged set yields exactly the globally-first `limit` visible listings.
func mergeVisibleListings(_ homes: [Home], limit: Int) -> [Home] {
    var seen = Set<String>()
    var merged: [Home] = []
    for home in recencyOrdered(homes) where seen.insert(home.id).inserted {
        merged.append(home)
        if merged.count == limit { break }
    }
    return merged
}

/// Combines the two visibility-partitioned snapshot listeners into a single
/// page callback. Firestore delivers snapshot callbacks on the main queue by
/// default, so the mutable state below is accessed serially without locking.
private final class VisibleListingsMerger: @unchecked Sendable {
    private let limit: Int
    private let handler: @Sendable (Result<[Home], Error>) -> Void
    private var everyoneHomes: [Home]?
    private var allowedHomes: [Home]?

    /// `awaitsAllowed: false` when no friends-only query is issued for this
    /// viewer, so `emit()` doesn't wait forever on a half that never arrives.
    init(
        limit: Int,
        awaitsAllowed: Bool,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) {
        self.limit = limit
        self.handler = handler
        self.allowedHomes = awaitsAllowed ? nil : []
    }

    func setEveryone(_ homes: [Home]) { everyoneHomes = homes; emit() }
    func setAllowed(_ homes: [Home]) { allowedHomes = homes; emit() }
    func fail(_ error: Error) { handler(.failure(error)) }

    private func emit() {
        guard let everyoneHomes, let allowedHomes else { return }
        handler(.success(mergeVisibleListings(everyoneHomes + allowedHomes, limit: limit)))
    }
}

struct FirestoreHomesRepository: HomesRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func decode(_ documents: [QueryDocumentSnapshot], context: StaticString) -> [Home] {
        documents.compactMap { doc in
            do { return try doc.data(as: Home.self) }
            catch {
                repoLog.error("\(context, privacy: .public) home decode \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // Firestore rejects an entire query if any matched document fails the read
    // rule, so the feed cannot be one unfiltered `homes` query once friends-only
    // listings are unreadable. Instead it is split along the two clauses the read
    // rule allows: publicly-visible listings, and listings whose denormalized
    // `allowedViewerIDs` names this viewer. Both are provably safe to the rules
    // engine. Their union (minus the overlap on the viewer's own public listings)
    // is exactly what the old client-side filter produced.
    // Recency order (createdAt DESC), with documentID DESC as a same-direction
    // tiebreak so a single composite index (its implicit __name__ DESC) serves
    // the whole order and cursor pagination has a total order to page against.
    private func everyoneQuery() -> Query {
        db.collection(FirestorePaths.homes)
            .whereField("visibility", isEqualTo: ListingVisibility.everyone.rawValue)
            .order(by: "createdAt", descending: true)
            .order(by: FieldPath.documentID(), descending: true)
    }

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
        // An anonymous guest is in nobody's viewer list; skip the friends-only
        // query rather than issuing one that can only ever return nothing.
        let hasViewer = !viewerID.isEmpty
        let merger = VisibleListingsMerger(limit: limit, awaitsAllowed: hasViewer, handler: handler)

        let everyoneReg = everyoneQuery()
            .limit(to: limit)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                if let error { merger.fail(error); return }
                guard let snapshot else { return }
                // Skip an empty cached snapshot — wait for the server confirmation
                // so the UI doesn't flash "no listings" before real data arrives.
                // Only this half is gated: the friends-only half is legitimately
                // empty for a viewer with no friends, and waiting on a server
                // snapshot for it would hang the feed offline.
                if snapshot.metadata.isFromCache && snapshot.isEmpty { return }
                merger.setEveryone(decode(snapshot.documents, context: "feed"))
            }

        guard hasViewer else { return FirestoreListenerBox(everyoneReg) }

        let allowedReg = allowedQuery(viewerID: viewerID)
            .limit(to: limit)
            .addSnapshotListener { snapshot, error in
                if let error { merger.fail(error); return }
                merger.setAllowed(decode(snapshot?.documents ?? [], context: "feed-allowed"))
            }

        return CompositeListener(listeners: [
            FirestoreListenerBox(everyoneReg),
            FirestoreListenerBox(allowedReg)
        ])
    }

    func listenToOwnListings(
        hostUserID: String,
        handler: @escaping @Sendable (Result<[Home], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection(FirestorePaths.homes)
            .whereField("hostUserID", isEqualTo: hostUserID)
            // Bound the listener so a prolific host doesn't stream every
            // listing they've ever created on each launch.
            .limit(to: ownListingsListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                handler(.success(decode(snapshot?.documents ?? [], context: "own")))
            }
        return FirestoreListenerBox(reg)
    }

    func fetchVisibleListings(viewerID: String, after cursor: ListingCursor?, limit: Int) async throws -> [Home] {
        try await withRetry {
            func page(_ query: Query) async throws -> [Home] {
                var query = query.limit(to: limit)
                // Cursor values must line up with the order-by fields:
                // createdAt (as a Timestamp) then the document id.
                if let cursor {
                    query = query.start(after: [Timestamp(date: cursor.createdAt), cursor.id])
                }
                return decode(try await query.getDocuments().documents, context: "page")
            }
            // Both suffixes are already recency-ordered, so the first `limit`
            // of their merge is the true next page of the union.
            async let everyone = page(everyoneQuery())
            guard !viewerID.isEmpty else {
                return mergeVisibleListings(try await everyone, limit: limit)
            }
            async let allowed = page(allowedQuery(viewerID: viewerID))
            return mergeVisibleListings(try await everyone + allowed, limit: limit)
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

    func updateHostName(userID: String, newName: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.homes)
                .whereField("hostUserID", isEqualTo: userID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            // Commit in chunks of 500 so a prolific host's rename doesn't
            // exceed Firestore's per-batch write limit.
            for start in stride(from: 0, to: refs.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for ref in refs[start..<min(start + firestoreBatchLimit, refs.count)] {
                    batch.updateData(["hostName": newName], forDocument: ref)
                }
                try await batch.commit()
            }
        }
    }

    func softDeleteAllListings(hostUserID: String) async throws {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.homes)
                .whereField("hostUserID", isEqualTo: hostUserID)
                .getDocuments()
            let refs = snap.documents.map(\.reference)
            let now = Timestamp(date: Date())
            // Chunk under the 500-op batch cap for hosts with many listings.
            for start in stride(from: 0, to: refs.count, by: firestoreBatchLimit) {
                let batch = db.batch()
                for ref in refs[start..<min(start + firestoreBatchLimit, refs.count)] {
                    batch.updateData(["deletedAt": now], forDocument: ref)
                }
                try await batch.commit()
            }
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
}

/// The two subcollection paths that implement progressive address disclosure.
/// Both the app and `firestore.rules` depend on these exact names; a typo here
/// silently hides addresses rather than failing loudly.
extension FirestorePaths {
    static func listingLocation(_ db: Firestore, homeID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.privateCollection).document(FirestorePaths.locationDocID)
    }

    /// Marker document whose mere existence grants `guestUserID` read access to
    /// the listing's private location. Written when the host accepts a stay.
    static func acceptedGuest(_ db: Firestore, homeID: String, guestUserID: String) -> DocumentReference {
        db.collection(FirestorePaths.homes).document(homeID).collection(FirestorePaths.accepted).document(guestUserID)
    }
}

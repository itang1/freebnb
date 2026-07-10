//
//  HomeStore.swift
//  freebnb
//

import FirebaseAuth
import Foundation
import Observation
import os

@MainActor
@Observable
final class HomeStore {
    private(set) var listings: [Home] = []
    /// The feed the UI renders: `listings` with blocked hosts and unreachable
    /// friends-only listings removed, ordered friends-first then by recency.
    /// Derived here (A1) so the filter-and-sort runs once when its inputs change,
    /// not on every view render as it did when this lived in `ContentView`.
    private(set) var visibleListings: [Home] = []
    private(set) var ownListings: [Home] = []
    /// Street addresses and exact coordinates the current user is allowed to see,
    /// keyed by listing id. Populated eagerly for the user's own listings and on
    /// demand elsewhere; a listing absent from this map is one whose address the
    /// user has not earned (or has not requested yet).
    private(set) var listingLocations: [String: ListingLocation] = [:]
    /// House manuals the current user is allowed to see, keyed by listing id.
    /// Cached on demand alongside `listingLocations`, gated by the same
    /// accepted-guest rule.
    private(set) var listingManuals: [String: HouseManual] = [:]
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = true
    private(set) var error: String?

    @ObservationIgnored private let repository: HomesRepository
    @ObservationIgnored private let photoUploader: PhotoUploader
    // `nonisolated(unsafe)` because `deinit` is nonisolated and must cancel
    // the listener. The property is only assigned from @MainActor contexts,
    // and `RepositoryListener.cancel()` is thread-safe per Firebase's docs
    // for `ListenerRegistration.remove()`.
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var ownListingsListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let log = AppLog.logger("homes")
    @ObservationIgnored private let pageSize = 25
    // Live first page (kept fresh by the snapshot listener) and the older pages
    // fetched on demand via cursor. `listings` is their de-duplicated, ordered
    // merge, so paging no longer re-downloads earlier pages on each load-more.
    @ObservationIgnored private var livePage: [Home] = []
    @ObservationIgnored private var pagedListings: [Home] = []
    // Pinned when the listener starts so `loadMore` pages the same partition the
    // live page came from, even if auth changes mid-scroll.
    @ObservationIgnored private var viewerID: String = ""
    // Listings whose private location has already been fetched, successfully or
    // not. A legacy listing has no location document, so caching only the hits
    // would refetch it on every own-listings snapshot.
    @ObservationIgnored private var attemptedLocationIDs: Set<String> = []
    // Feed derivation context supplied by the surrounding stores (auth, friends,
    // blocks). Held here so `visibleListings` recomputes only when it or the raw
    // listings change. See `updateFeedContext`.
    @ObservationIgnored private var feedContext = FeedContext()

    init(
        repository: HomesRepository = FirestoreHomesRepository(),
        photoUploader: PhotoUploader = NoopPhotoUploader()
    ) {
        self.repository = repository
        self.photoUploader = photoUploader
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restartListener(signedIn: user != nil) }
        }
    }

    deinit {
        activeListener?.cancel()
        ownListingsListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Paginated listener

    private func restartListener(signedIn: Bool? = nil) {
        activeListener?.cancel()
        activeListener = nil
        ownListingsListener?.cancel()
        ownListingsListener = nil
        let uid = Auth.auth().currentUser?.uid
        guard signedIn ?? (uid != nil) else {
            livePage = []
            pagedListings = []
            listings = []
            visibleListings = []
            ownListings = []
            // Addresses are entitlements of the signed-in user, not of the device.
            listingLocations = [:]
            listingManuals = [:]
            attemptedLocationIDs = []
            viewerID = ""
            canLoadMore = true
            isLoading = false
            return
        }
        isLoading = true
        // Re-establishing the live first page invalidates any fetched older
        // pages, so start paging fresh.
        pagedListings = []
        canLoadMore = true
        viewerID = currentViewerID
        // The live listener covers only the first page. Fetch one past the page
        // size so we can tell "more exist beyond the first page" from "that's
        // all" without an extra round trip.
        activeListener = repository.listenToVisibleListings(viewerID: viewerID, limit: pageSize + 1) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.apply(result: result)
            }
        }
        if let uid {
            ownListingsListener = repository.listenToOwnListings(hostUserID: uid) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.applyOwnListings(result: result)
                }
            }
        }
    }

    // Guests can never appear in a listing's `allowedViewerIDs` (they cannot be
    // friends), so they browse as an empty viewer and skip that query entirely.
    private var currentViewerID: String {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return "" }
        return user.uid
    }

    private func applyOwnListings(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("own listings snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let homes):
            ownListings = homes.filter { $0.deletedAt == nil }
            // A host can always read their own listings' addresses, and every host
            // surface (the listing rows, the dashboard, the edit form, the incoming
            // request rows) wants them. Bounded by ownListingsListenerLimit.
            let missing = ownListings.map(\.id).filter { !attemptedLocationIDs.contains($0) }
            guard !missing.isEmpty else { return }
            attemptedLocationIDs.formUnion(missing)
            Task { @MainActor in
                for homeID in missing { await location(for: homeID) }
            }
        }
    }

    // MARK: - Progressive address disclosure

    /// Fetches and caches the listing's street address. Returns nil when the
    /// caller isn't entitled to it — a guest without an accepted stay — which is
    /// the expected answer, not an error worth surfacing.
    @discardableResult
    func location(for homeID: String) async -> ListingLocation? {
        if let cached = listingLocations[homeID] { return cached }
        do {
            guard let location = try await repository.fetchLocation(homeID: homeID) else { return nil }
            listingLocations[homeID] = location
            return location
        } catch {
            log.info("location unavailable for \(homeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fetches and caches the listing's house manual. Returns nil when the caller
    /// isn't an accepted guest or the host hasn't written one — both expected,
    /// non-error outcomes.
    @discardableResult
    func manual(for homeID: String) async -> HouseManual? {
        if let cached = listingManuals[homeID] { return cached }
        do {
            guard let manual = try await repository.fetchManual(homeID: homeID) else { return nil }
            listingManuals[homeID] = manual
            return manual
        } catch {
            log.info("manual unavailable for \(homeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes the host's house manual and refreshes the local cache so the editor
    /// and the guest-facing card reflect it immediately.
    func saveManual(homeID: String, manual: HouseManual) async throws {
        do {
            try await repository.saveManual(homeID: homeID, manual: manual)
            listingManuals[homeID] = manual
        } catch {
            log.error("manual save error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func apply(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            isLoading = false
        case .success(let raw):
            self.error = nil
            // The sentinel (pageSize + 1) tells us whether more listings exist
            // beyond the live first page. Once older pages have been fetched,
            // their own paging owns canLoadMore, so don't overwrite it here.
            let firstPageHasMore = raw.count > pageSize
            livePage = Array(raw.filter { $0.deletedAt == nil }.prefix(pageSize))
            if pagedListings.isEmpty { canLoadMore = firstPageHasMore }
            isLoading = false
            recompute()
        }
    }

    // Merge the live first page with any fetched older pages into one
    // de-duplicated list in recency order (newest first).
    private func recompute() {
        var seen = Set<String>()
        var merged: [Home] = []
        for home in recencyOrdered(livePage + pagedListings)
            where seen.insert(home.id).inserted {
            merged.append(home)
        }
        listings = merged
        recomputeVisible()
    }

    // MARK: - Derived feed (A1)

    /// Supplies the viewer identity, friend set, and block set the feed is
    /// filtered and ranked against. Recomputes `visibleListings` only when the
    /// context actually changes, so the view layer can call this freely.
    func updateFeedContext(myID: String, friendIDs: Set<String>, blockedIDs: Set<String>) {
        let next = FeedContext(myID: myID, friendIDs: friendIDs, blockedIDs: blockedIDs)
        guard next != feedContext else { return }
        feedContext = next
        recomputeVisible()
    }

    private func recomputeVisible() {
        visibleListings = Self.feed(
            from: listings,
            myID: feedContext.myID,
            friendIDs: feedContext.friendIDs,
            blockedIDs: feedContext.blockedIDs
        )
    }

    /// Filters out blocked hosts and restricted listings you can't see, then
    /// orders friends' listings first, then your own, then everyone else.
    ///
    /// Firestore rules and the partitioned feed queries are what actually keep a
    /// restricted listing out of a stranger's hands; the visibility check here
    /// is a second line of defence for a stale `allowedViewerIDs` (a friend
    /// removed since the listing was last written). Block filtering, by contrast,
    /// is client-only by design — the block list is private to the blocker.
    ///
    /// A `friendsOfFriends` listing can only be judged by the ACL: the viewer's
    /// second-degree connections are not knowable client-side, since a user may
    /// read only their own friend edges. `friendsOnly` gets the stricter check
    /// because there the client *can* verify the claim.
    ///
    /// Within a rank bucket, newest listings come first (L3). Swift's sort is not
    /// stable, so the comparator falls through to the listing id: without a total
    /// order, rows sharing a rank and timestamp reshuffle between recomputes.
    nonisolated static func feed(
        from listings: [Home],
        myID: String,
        friendIDs: Set<String>,
        blockedIDs: Set<String>
    ) -> [Home] {
        listings
            .filter { home in
                guard !blockedIDs.contains(home.hostUserID) else { return false }
                guard home.hostUserID != myID else { return true }
                // A listing with no stored visibility predates the field and reads
                // as public, the same default the rules apply.
                switch home.visibility ?? .everyone {
                case .friendsOnly:
                    return friendIDs.contains(home.hostUserID)
                case .friendsOfFriends:
                    return friendIDs.contains(home.hostUserID)
                        || (home.allowedViewerIDs ?? []).contains(myID)
                case .everyone:
                    return true
                }
            }
            .sorted { a, b in
                let aRank = feedRank(a, myID: myID, friendIDs: friendIDs)
                let bRank = feedRank(b, myID: myID, friendIDs: friendIDs)
                if aRank != bRank { return aRank < bRank }
                let aDate = a.createdAt ?? .distantPast
                let bDate = b.createdAt ?? .distantPast
                if aDate != bDate { return aDate > bDate }
                return a.id < b.id
            }
    }

    /// Lower sorts earlier: friends' listings, then your own, then everyone else.
    nonisolated static func feedRank(_ home: Home, myID: String, friendIDs: Set<String>) -> Int {
        if friendIDs.contains(home.hostUserID) { return 0 }
        if home.hostUserID == myID { return 1 }
        return 2
    }

    func loadMore() {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        // Page after the last loaded listing's (createdAt, id); no earlier pages
        // are re-downloaded. A listing sourced from the ordered query always has
        // a createdAt, so this is nil only when the list is empty.
        let cursor = listings.last.flatMap { last in
            last.createdAt.map { ListingCursor(createdAt: $0, id: last.id) }
        }
        Task { @MainActor in
            do {
                let next = try await repository.fetchVisibleListings(viewerID: viewerID, after: cursor, limit: pageSize)
                pagedListings.append(contentsOf: next)
                canLoadMore = next.count == pageSize
                self.error = nil
                recompute()
            } catch {
                log.error("load more error: \(error.localizedDescription, privacy: .public)")
                self.error = error.localizedDescription
            }
            isLoadingMore = false
        }
    }

    func reload() {
        restartListener(signedIn: true)
    }

    // MARK: - Writes

    // Both writes throw on failure so the caller can surface an error in the
    // UI. The store logs regardless, so failures are never silent.

    /// Saves the world-readable listing document and, when `location` is given,
    /// the private street address alongside it. The public document is written
    /// first: a listing with no address is recoverable by re-saving, whereas an
    /// address with no listing is orphaned data the rules can't even reach.
    func save(_ home: Home, location: ListingLocation? = nil) async throws {
        do {
            try await repository.save(home)
            if let location {
                try await repository.saveLocation(homeID: home.id, location: location)
                listingLocations[home.id] = location
                attemptedLocationIDs.insert(home.id)
            }
        } catch {
            log.error("save error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Uploads any attached images in parallel, then saves the listing with
    /// the resulting URLs. If `images` is empty the upload step is skipped.
    /// Errors from either step propagate so the caller can show them.
    func createListing(home: Home, images: [Data]) async throws {
        var updated = home
        if !images.isEmpty {
            let urls = try await uploadImages(images, for: home)
            updated.photoURLs = urls.map(\.absoluteString)
        }
        try await save(updated)
    }

    /// Uploads in parallel but returns the URLs in the order the images were given.
    /// A task group yields results as they finish, so appending them as they arrive
    /// would order a listing's photos by upload speed — and `photoURLs[0]` is the
    /// card's cover image, which the host chose deliberately.
    private func uploadImages(_ images: [Data], for home: Home) async throws -> [URL] {
        let uploader = photoUploader
        let listingID = home.id
        let hostUserID = home.hostUserID
        return try await withThrowingTaskGroup(of: (offset: Int, url: URL).self) { group in
            for (offset, data) in images.enumerated() {
                group.addTask {
                    (offset, try await uploader.upload(imageData: data, listingID: listingID, hostUserID: hostUserID))
                }
            }
            var urls = [URL?](repeating: nil, count: images.count)
            for try await (offset, url) in group { urls[offset] = url }
            return urls.compactMap { $0 }
        }
    }

    func delete(_ home: Home) async throws {
        do {
            try await repository.delete(homeID: home.id)
        } catch {
            log.error("delete error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func updateHostName(for userID: String, newName: String) async throws {
        do {
            try await repository.updateHostName(userID: userID, newName: newName)
        } catch {
            log.error("update host name error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// The viewer-specific inputs the feed is filtered and ranked against. Equatable
/// so `HomeStore` can skip recomputing the feed when nothing relevant changed.
struct FeedContext: Equatable {
    var myID: String = ""
    var friendIDs: Set<String> = []
    var blockedIDs: Set<String> = []
}

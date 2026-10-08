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
    /// The feed the UI renders: `listings` minus blocked hosts and unreachable
    /// listings, friends first then by recency.
    private(set) var visibleListings: [Home] = []
    /// Listings the user hosts or co-hosts. Check `Home.isHostedBy(_:)` before
    /// offering host-only actions.
    private(set) var managedListings: [Home] = []
    /// Addresses the user may see, keyed by listing id. A missing entry means not
    /// earned or not fetched yet.
    private(set) var listingLocations: [String: ListingLocation] = [:]
    /// House manuals the user may see, keyed by listing id (accepted guests only).
    private(set) var listingManuals: [String: HouseManual] = [:]
    /// Unmerged calendars of managed listings, keyed by listing id. Guests can't
    /// read these.
    private(set) var listingAvailability: [String: ListingAvailability] = [:]
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = true
    private(set) var error: String?

    @ObservationIgnored private let repository: HomesRepository
    @ObservationIgnored private let photoUploader: PhotoUploader
    // `nonisolated(unsafe)` so the nonisolated `deinit` can cancel the listener;
    // `cancel()` is thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var managedListingsListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let log = AppLog.logger("homes")
    @ObservationIgnored private let pageSize = 25
    // Live first page plus older pages fetched by cursor; `listings` is their merge.
    @ObservationIgnored private var livePage: [Home] = []
    @ObservationIgnored private var pagedListings: [Home] = []
    // Pinned at listener start so `loadMore` pages the same partition as the live page.
    @ObservationIgnored private var viewerID: String = ""
    // Listings whose location fetch was already attempted. Legacy listings have no
    // location doc, so caching only hits would refetch them every snapshot.
    @ObservationIgnored private var attemptedLocationIDs: Set<String> = []
    // Viewer, friends and blocks the feed is derived from; see `updateFeedContext`.
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
        managedListingsListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Paginated listener

    private func restartListener(signedIn: Bool? = nil) {
        activeListener?.cancel()
        activeListener = nil
        managedListingsListener?.cancel()
        managedListingsListener = nil
        let uid = Auth.auth().currentUser?.uid
        guard signedIn ?? (uid != nil) else {
            livePage = []
            pagedListings = []
            listings = []
            visibleListings = []
            managedListings = []
            // Addresses belong to the signed-in user, not the device.
            listingLocations = [:]
            listingManuals = [:]
            listingAvailability = [:]
            attemptedLocationIDs = []
            viewerID = ""
            canLoadMore = true
            isLoading = false
            return
        }
        isLoading = true
        // A fresh live page invalidates fetched older pages.
        pagedListings = []
        canLoadMore = true
        viewerID = currentViewerID
        // Fetch one past the page size to learn whether more exist without an extra query.
        activeListener = repository.listenToVisibleListings(viewerID: viewerID, limit: pageSize + 1) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.apply(result: result)
            }
        }
        if let uid {
            managedListingsListener = repository.listenToManagedListings(userID: uid) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.applyManagedListings(result: result)
                }
            }
        }
    }

    // Guests can't be friends, so they browse as an empty viewer and skip the query.
    private var currentViewerID: String {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return "" }
        return user.uid
    }

    private func applyManagedListings(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("managed listings snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let homes):
            managedListings = homes.filter { $0.deletedAt == nil }
            // Managers can always read their listings' addresses, and every
            // management surface wants them (co-hosts included).
            let missing = managedListings.map(\.id).filter { !attemptedLocationIDs.contains($0) }
            guard !missing.isEmpty else { return }
            attemptedLocationIDs.formUnion(missing)
            Task { @MainActor in
                for homeID in missing { await location(for: homeID) }
            }
        }
    }

    // MARK: - Progressive address disclosure

    /// Fetches and caches the street address. Nil when the caller isn't entitled
    /// to it, which is expected rather than an error.
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

    /// Fetches and caches the house manual. Nil for non-accepted guests or when
    /// none was written.
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

    /// Writes the manual and updates the local cache.
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
            // The extra sentinel row says whether more exist; once older pages are
            // loaded, their paging owns canLoadMore.
            let firstPageHasMore = raw.count > pageSize
            livePage = Array(raw.filter { $0.deletedAt == nil }.prefix(pageSize))
            if pagedListings.isEmpty { canLoadMore = firstPageHasMore }
            isLoading = false
            recompute()
        }
    }

    // Merges live and older pages, de-duplicated, newest first.
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

    // MARK: - Derived feed

    /// Supplies the viewer, friend and block sets the feed is built from.
    /// Recomputes only when they change.
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

    /// Drops blocked hosts and non-friends, then orders friends' listings first,
    /// your own next, everyone else last; newest first within a rank.
    ///
    /// The friendship check backs up a stale `allowedViewerIDs`; block filtering
    /// is client-only because the block list is private. The id tiebreak keeps
    /// the order total so equal rows don't reshuffle.
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
                return friendIDs.contains(home.hostUserID)
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

    /// Lower sorts earlier.
    nonisolated static func feedRank(_ home: Home, myID: String, friendIDs: Set<String>) -> Int {
        if friendIDs.contains(home.hostUserID) { return 0 }
        if home.hostUserID == myID { return 1 }
        return 2
    }

    func loadMore() {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        // Page after the last listing's (createdAt, id); nil only when the list is empty.
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

    // Writes throw so callers can surface errors; the store logs regardless.

    /// Saves the listing, then the private address if given. Public doc first:
    /// a listing missing its address is fixed by re-saving; an orphaned address isn't.
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

    // MARK: - Read ACL upkeep

    /// Seeds `managedListings` without a listener, for tests.
    func setManagedListingsForTesting(_ listings: [Home]) {
        managedListings = listings
    }

    /// Rewrites the viewer ACL on hosted listings to match current friends.
    ///
    /// Stands in for the `onFriendEdgeWritten` Cloud Function, which prod doesn't
    /// have. Each client only writes its own listings, so the two sides converge
    /// as each opens the app. Writes only on a real change.
    func refreshOwnListingACLs(myID: String, friendIDs: some Sequence<String>) async {
        guard !myID.isEmpty else { return }
        let desired = Home.viewerIDs(hostUserID: myID, friendIDs: friendIDs)
        for listing in managedListings where listing.isHostedBy(myID) {
            guard Set(listing.allowedViewerIDs ?? []) != Set(desired) else { continue }
            var updated = listing
            updated.allowedViewerIDs = desired
            do {
                try await repository.save(updated)
            } catch {
                // Best effort; the next launch retries.
                log.error("ACL refresh failed for \(listing.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Booked-range reconciliation

    /// Recomputes hosted listings' booked dates from their accepted stays and
    /// republishes the calendar.
    ///
    /// Accepted stays are the only source that survives a lost callable (a guest
    /// accepting an offer can't write the listing). Idempotent, writes only on a
    /// real change, and runs from the host's incoming-requests listener and on launch.
    func reconcileBookedRanges(hostUserID: String, acceptedStays: [StayRequest]) async {
        guard !hostUserID.isEmpty else { return }

        let byListing = Dictionary(grouping: acceptedStays.filter { $0.status == .accepted }) {
            $0.listingID
        }

        for listing in managedListings where listing.isHostedBy(hostUserID) {
            let booked = Self.normalizedRanges(
                (byListing[listing.id] ?? []).map { DateRange(start: $0.checkIn, end: $0.checkOut) }
            )
            // Read from the repository, not the cache, which may not have seen this
            // snapshot; the blocked half must be the stored one or the union drops a new block.
            guard let current = try? await repository.fetchAvailability(homeID: listing.id) else { continue }
            guard Self.rangesDiffer(current.bookedDateRanges, booked) else { continue }

            var updated = current
            updated.bookedDateRanges = booked
            do {
                try await repository.saveBookedRanges(homeID: listing.id, booked: booked)

                var published = listing
                let union = updated.unavailableRanges
                published.unavailableDateRanges = union.isEmpty ? nil : union
                try await repository.save(published)
            } catch {
                // Best effort; the next change or launch recomputes.
                log.error("booked reconcile failed for \(listing.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sorts by start and merges overlapping or touching ranges so stored ranges are canonical.
    static func normalizedRanges(_ ranges: [DateRange]) -> [DateRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [DateRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = DateRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Order-independent inequality, so a reshuffled recompute doesn't trigger a write.
    private static func rangesDiffer(_ a: [DateRange], _ b: [DateRange]) -> Bool {
        normalizedRanges(a) != normalizedRanges(b)
    }

    // MARK: - Availability

    /// Fetches and caches a managed listing's calendar, blocked and booked kept
    /// apart. Empty when not entitled or nothing is closed yet.
    @discardableResult
    func availability(for homeID: String) async -> ListingAvailability {
        if let cached = listingAvailability[homeID] { return cached }
        do {
            let availability = try await repository.fetchAvailability(homeID: homeID)
            listingAvailability[homeID] = availability
            return availability
        } catch {
            log.info("availability unavailable for \(homeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ListingAvailability()
        }
    }

    /// Writes the host's blocked half, then republishes the merged copy the
    /// public listing carries. The private half is the source of truth, so it
    /// lands first. The booked half is left untouched.
    func saveBlockedRanges(_ blocked: [DateRange], for home: Home) async throws {
        var updated = await availability(for: home.id)
        do {
            try await repository.saveBlockedRanges(homeID: home.id, blocked: blocked)
            updated.blockedDateRanges = blocked
            try await republishCalendar(updated, for: home)
        } catch {
            log.error("availability save error for \(home.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Adds `ranges` to the blocked dates of every other listing this user hosts
    /// (a union, never a replace; co-hosted listings are skipped). A one-time
    /// copy, not a link. Returns ids it couldn't update; safe to re-run.
    func applyBlockedRangesToOtherHostedListings(
        _ ranges: [DateRange],
        excludingID: String,
        hostUserID: String
    ) async -> [String] {
        let others = managedListings.filter { $0.isHostedBy(hostUserID) && $0.id != excludingID }
        let addedDays = AvailabilityCalendar.blockedDays(in: ranges)
        var failed: [String] = []
        for home in others {
            let existing = await availability(for: home.id)
            let merged = AvailabilityCalendar.merging(existing.blockedDateRanges, adding: addedDays)
            do {
                try await saveBlockedRanges(merged, for: home)
            } catch {
                log.error("apply-to-all save failed for \(home.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(home.id)
            }
        }
        return failed
    }

    /// Uploads attached images in parallel, then saves the listing with their URLs.
    func createListing(home: Home, images: [Data]) async throws {
        var updated = home
        if !images.isEmpty {
            let urls = try await uploadImages(images, for: home)
            updated.photoURLs = urls.map(\.absoluteString)
        }
        try await save(updated)
    }

    /// Uploads in parallel but returns URLs in the given order, since `photoURLs[0]` is the cover.
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

    // MARK: - Co-hosts

    /// Adds one friend as co-host. One at a time because the rules can only check
    /// a single added id against the friend graph; a batch would be rejected.
    func addCoHost(_ userID: String, to home: Home, hostUserID: String) async throws {
        guard home.isHostedBy(hostUserID) else { throw CoHostError.notTheHost }
        guard userID != home.hostUserID else { throw CoHostError.hostCannotCoHost }
        guard !home.coHosts.contains(userID) else { return }
        guard home.coHosts.count < Home.maxCoHosts else { throw CoHostError.rosterFull }

        var updated = home
        updated.coHostUserIDs = home.coHosts + [userID]
        try await saveRoster(updated)
    }

    /// Removes a co-host. Needs no friend edge, since revoking is always safe.
    func removeCoHost(_ userID: String, from home: Home, hostUserID: String) async throws {
        guard home.isHostedBy(hostUserID) else { throw CoHostError.notTheHost }
        var updated = home
        updated.coHostUserIDs = home.coHosts.filter { $0 != userID }
        try await saveRoster(updated)
    }

    /// Writes a roster change only, via `repository.save`, so a stale street address is never carried.
    private func saveRoster(_ home: Home) async throws {
        do {
            try await repository.save(home)
        } catch {
            log.error("co-host save error: \(error.localizedDescription, privacy: .public)")
            throw error
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

// MARK: - Availability publishing
extension HomeStore {
    /// Caches `availability` and rewrites the public listing's merged calendar:
    /// blocked days, booked days and the turnover buffer collapse into one
    /// `unavailableDateRanges`.
    func republishCalendar(_ availability: ListingAvailability, for home: Home) async throws {
        listingAvailability[home.id] = availability
        var published = home
        let union = availability.unavailableRanges
        published.unavailableDateRanges = union.isEmpty ? nil : union
        try await repository.save(published)
    }

    /// Writes the turnover buffer and republishes the merged calendar. Private field first.
    func saveBufferHours(_ bufferHours: Int, for home: Home) async throws {
        var updated = await availability(for: home.id)
        do {
            try await repository.saveBufferHours(homeID: home.id, bufferHours: bufferHours)
            updated.bufferHours = bufferHours
            try await republishCalendar(updated, for: home)
        } catch {
            log.error("buffer save error for \(home.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Co-host roster failures the UI can anticipate; the rules refuse everything else.
enum CoHostError: LocalizedError {
    case notTheHost
    case hostCannotCoHost
    case rosterFull

    var errorDescription: String? {
        switch self {
        case .notTheHost:
            return "Only the host can change who co-hosts this listing."
        case .hostCannotCoHost:
            return "You already host this listing."
        case .rosterFull:
            return "A listing can have at most \(Home.maxCoHosts) co-hosts."
        }
    }
}

/// Viewer-specific feed inputs; Equatable so unchanged context skips recomputing.
struct FeedContext: Equatable {
    var myID: String = ""
    var friendIDs: Set<String> = []
    var blockedIDs: Set<String> = []
}

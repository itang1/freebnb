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
    private(set) var ownListings: [Home] = []
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
    @ObservationIgnored private let pageSize = 20
    @ObservationIgnored private var currentLimit: Int

    init(
        repository: HomesRepository = FirestoreHomesRepository(),
        photoUploader: PhotoUploader = NoopPhotoUploader()
    ) {
        self.repository = repository
        self.photoUploader = photoUploader
        self.currentLimit = pageSize
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
        guard signedIn ?? (Auth.auth().currentUser != nil) else {
            listings = []
            ownListings = []
            isLoading = false
            return
        }
        isLoading = true
        // Fetch one past the limit so we can tell "page full, more exist" apart
        // from "page full, nothing more" without an extra round trip.
        activeListener = repository.listenToListings(limit: currentLimit + 1) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.apply(result: result)
            }
        }
        if let uid = Auth.auth().currentUser?.uid {
            ownListingsListener = repository.listenToOwnListings(hostUserID: uid) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.applyOwnListings(result: result)
                }
            }
        }
    }

    private func applyOwnListings(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("own listings snapshot error: \(error.localizedDescription, privacy: .public)")
        case .success(let homes):
            ownListings = homes.filter { $0.deletedAt == nil }
        }
    }

    private func apply(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            isLoading = false
            isLoadingMore = false
            // Firestore stops delivering updates after an error; cancel the dead
            // listener so loadMore() can restart it cleanly.
            activeListener?.cancel()
            activeListener = nil
        case .success(let homes):
            self.error = nil
            // `canLoadMore` is checked before filtering so that the sentinel doc
            // (limit+1) still triggers paging even if some results are deleted.
            canLoadMore = homes.count > currentLimit
            listings = Array(homes.filter { $0.deletedAt == nil }.prefix(currentLimit))
            isLoading = false
            isLoadingMore = false
        }
    }

    func loadMore() {
        guard !isLoadingMore else { return }
        // Also allow calling loadMore() to retry after a listener error.
        guard canLoadMore || error != nil else { return }
        isLoadingMore = true
        if error == nil { currentLimit += pageSize }
        restartListener(signedIn: true)
    }

    func reload() {
        currentLimit = pageSize
        restartListener(signedIn: true)
    }

    // MARK: - Writes

    // Both writes throw on failure so the caller can surface an error in the
    // UI. The store logs regardless, so failures are never silent.

    func save(_ home: Home) async throws {
        do {
            try await repository.save(home)
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

    private func uploadImages(_ images: [Data], for home: Home) async throws -> [URL] {
        let uploader = photoUploader
        let listingID = home.id
        let hostUserID = home.hostUserID
        return try await withThrowingTaskGroup(of: URL.self) { group in
            for data in images {
                group.addTask {
                    try await uploader.upload(imageData: data, listingID: listingID, hostUserID: hostUserID)
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
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

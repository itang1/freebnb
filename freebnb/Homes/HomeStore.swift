//
//  HomeStore.swift
//  freebnb
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class HomeStore {
    private(set) var listings: [Home] = []
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
        restartListener()
    }

    deinit { activeListener?.cancel() }

    // MARK: - Paginated listener

    private func restartListener() {
        activeListener?.cancel()
        // Fetch one past the limit so we can tell "page full, more exist" apart
        // from "page full, nothing more" without an extra round trip.
        activeListener = repository.listenToListings(limit: currentLimit + 1) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.apply(result: result)
            }
        }
    }

    private func apply(result: Result<[Home], Error>) {
        switch result {
        case .failure(let error):
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            isLoading = false
            isLoadingMore = false
        case .success(let homes):
            self.error = nil
            canLoadMore = homes.count > currentLimit
            listings = Array(homes.prefix(currentLimit))
            isLoading = false
            isLoadingMore = false
        }
    }

    func loadMore() {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        currentLimit += pageSize
        restartListener()
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
}

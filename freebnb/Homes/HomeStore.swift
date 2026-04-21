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
    @ObservationIgnored nonisolated(unsafe) private var activeListener: RepositoryListener?
    @ObservationIgnored private let log = AppLog.logger("homes")
    @ObservationIgnored private let pageSize = 20
    @ObservationIgnored private var currentLimit: Int

    init(repository: HomesRepository = FirestoreHomesRepository()) {
        self.repository = repository
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

    func delete(_ home: Home) async throws {
        do {
            try await repository.delete(homeID: home.id)
        } catch {
            log.error("delete error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

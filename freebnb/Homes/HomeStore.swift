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
    @ObservationIgnored private var activeListener: RepositoryListener?
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "homes")
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
        activeListener = repository.listenToListings(limit: currentLimit) { [weak self] result in
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
            listings = homes
            canLoadMore = homes.count >= currentLimit
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

    func save(_ home: Home) {
        Task {
            do { try await repository.save(home) }
            catch { log.error("save error: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func delete(_ home: Home) {
        Task {
            do { try await repository.delete(homeID: home.id) }
            catch { log.error("delete error: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

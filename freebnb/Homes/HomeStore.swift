//
//  HomeStore.swift
//  freebnb
//

import FirebaseFirestore
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class HomeStore {
    private(set) var listings: [Home] = []
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = true
    private(set) var error: String?

    @ObservationIgnored nonisolated(unsafe) private var listener: ListenerRegistration?
    @ObservationIgnored private let db = Firestore.firestore()
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "homes")
    @ObservationIgnored private let pageSize = 20
    @ObservationIgnored private var currentLimit: Int

    init() {
        currentLimit = pageSize
        restartListener()
    }

    deinit { listener?.remove() }

    // MARK: - Paginated listener
    //
    // We keep a single live listener whose limit grows as the user scrolls. This
    // way all loaded listings stay in sync with real-time edits. The trade-off is
    // that each loadMore re-reads the whole loaded prefix; acceptable up to a few
    // hundred docs. Beyond that, split into per-page one-shot queries.

    private func restartListener() {
        listener?.remove()
        listener = db.collection("homes")
            .order(by: FieldPath.documentID())
            .limit(to: currentLimit)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    self?.apply(snapshot: snapshot, error: error)
                }
            }
    }

    private func apply(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            log.error("snapshot error: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            isLoading = false
            isLoadingMore = false
            return
        }
        self.error = nil
        let docs = snapshot?.documents ?? []
        listings = docs.compactMap { doc -> Home? in
            do { return try doc.data(as: Home.self) }
            catch {
                log.error("decode error \(doc.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        canLoadMore = docs.count >= currentLimit
        isLoading = false
        isLoadingMore = false
    }

    func loadMore() {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        currentLimit += pageSize
        restartListener()
    }

    // MARK: - Write

    func save(_ home: Home) {
        do {
            try db.collection("homes").document(home.id).setData(from: home)
        } catch {
            log.error("encode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ home: Home) {
        db.collection("homes").document(home.id).delete()
    }
}

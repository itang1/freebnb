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
    private(set) var error: String?

    @ObservationIgnored nonisolated(unsafe) private var listener: ListenerRegistration?
    @ObservationIgnored private let db = Firestore.firestore()
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "homes")

    init() { startListening() }
    deinit { listener?.remove() }

    // MARK: - Real-time listener

    private func startListening() {
        listener = db.collection("homes").addSnapshotListener { [weak self] snapshot, error in
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
        isLoading = false
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

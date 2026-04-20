//
//  HomeStore.swift
//  freebnb
//

import FirebaseFirestore
import SwiftUI

class HomeStore: ObservableObject {
    @Published var listings: [Home] = []
    @Published var isLoading = true
    @Published var error: String?

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()

    init() { startListening() }
    deinit { listener?.remove() }

    // MARK: - Real-time listener

    private func startListening() {
        listener = db.collection("homes").addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    print("HomeStore error: \(error)")
                    self.error = error.localizedDescription
                    self.isLoading = false
                    return
                }
                let docs = snapshot?.documents ?? []
                self.listings = docs.compactMap { doc -> Home? in
                    do { return try doc.data(as: Home.self) }
                    catch { print("HomeStore decode error \(doc.documentID): \(error)"); return nil }
                }
                self.isLoading = false
            }
        }
    }

    // MARK: - Write

    func save(_ home: Home) {
        do {
            try db.collection("homes").document(home.id).setData(from: home)
        } catch {
            print("HomeStore encode error: \(error)")
        }
    }

    func delete(_ home: Home) {
        db.collection("homes").document(home.id).delete()
    }
}

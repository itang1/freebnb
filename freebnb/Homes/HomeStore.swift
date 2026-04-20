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
                print("HomeStore: received \(docs.count) documents")
                self.listings = docs.compactMap { doc in
                    if let home = self.decode(doc) {
                        return home
                    } else {
                        print("HomeStore: failed to decode document \(doc.documentID): \(doc.data())")
                        return nil
                    }
                }
                self.isLoading = false
            }
        }
    }

    // MARK: - Write

    func save(_ home: Home) {
        guard let data = encoded(home) else { return }
        db.collection("homes").document(home.id).setData(data)
    }

    func delete(_ home: Home) {
        db.collection("homes").document(home.id).delete()
    }

    // MARK: - Codable helpers

    private func decode(_ document: QueryDocumentSnapshot) -> Home? {
        var data = document.data()
        data["id"] = document.documentID
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let home = try? JSONDecoder().decode(Home.self, from: jsonData)
        else { return nil }
        return home
    }

    private func encoded(_ home: Home) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(home),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
}

//
//  FriendEdgeRepository.swift
//  freebnb
//
//  The friend graph: friend-edge listeners and writes. Split out of the former
//  Repositories.swift (A2).
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

// Upper bound for the friend-edges snapshot listener.
private let friendEdgesListenerLimit = 500

protocol FriendEdgeRepository: Sendable {
    func listenToEdges(
        userID: String,
        field: String,
        handler: @escaping @Sendable (Result<[FriendEdge], Error>) -> Void
    ) -> RepositoryListener

    func createEdge(_ edge: FriendEdge) async throws
    func updateStatus(edgeID: String, status: FriendStatus) async throws
    func deleteEdge(edgeID: String) async throws
}

struct FirestoreFriendEdgeRepository: FriendEdgeRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    func listenToEdges(
        userID: String,
        field: String,
        handler: @escaping @Sendable (Result<[FriendEdge], Error>) -> Void
    ) -> RepositoryListener {
        let reg = db.collection(FirestorePaths.friendEdges)
            .whereField(field, isEqualTo: userID)
            .limit(to: friendEdgesListenerLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let edges: [FriendEdge] = (snapshot?.documents ?? []).compactMap { doc in
                    do { return try doc.data(as: FriendEdge.self) }
                    catch {
                        Telemetry.decodeFailure(collection: FirestorePaths.friendEdges, documentID: doc.documentID, error: error)
                        return nil
                    }
                }
                handler(.success(edges))
            }
        return FirestoreListenerBox(reg)
    }

    func createEdge(_ edge: FriendEdge) async throws {
        let edgeID = FriendEdge.edgeID(edge.userA, edge.userB)
        try await withRetry { [db] in
            try db.collection(FirestorePaths.friendEdges).document(edgeID).setData(from: edge)
        }
    }

    func updateStatus(edgeID: String, status: FriendStatus) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.friendEdges).document(edgeID).updateData([
                "status": status.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func deleteEdge(edgeID: String) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.friendEdges).document(edgeID).delete()
        }
    }
}

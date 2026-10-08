//
//  FriendNoteRepository.swift
//  freebnb
//
//  Reads and writes for a host's private notes on friends. One audience, unlike
//  `CircleRepository`: only the author reads a note, so there's no projection or fan-out,
//  and a "guest side" appearing below would mean something went wrong. One live listener
//  covers the whole set, since notes are few and per-friend queries need a composite index for nothing.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation

/// High enough that no real host reaches it, low enough that a runaway client can't pull an unbounded collection.
private let friendNotesFetchLimit = 1000

protocol FriendNoteRepository: Sendable {
    /// Every note this host wrote, across friends, newest first.
    func listenToNotes(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendNote], Error>) -> Void
    ) -> RepositoryListener

    /// Which stays this host was already asked about, so the post-stay prompt asks once.
    func listenToPrompts(
        hostID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener

    /// Writes a new note and returns its id.
    @discardableResult
    func createNote(hostID: String, _ note: FriendNote) async throws -> String
    /// Revises a note's text and stay link, never its subject (the rules refuse a re-pointed note).
    func updateNote(hostID: String, noteID: String, text: String, stayRequestID: String?) async throws
    func deleteNote(hostID: String, noteID: String) async throws

    /// Marks one stay's post-stay prompt dealt with, whether the host wrote or waved it off: they were asked and answered.
    func markPromptSeen(hostID: String, stayRequestID: String) async throws
}

struct FirestoreFriendNoteRepository: FriendNoteRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func notes(_ hostID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(hostID).collection(FirestorePaths.friendNotes)
    }

    private func prompts(_ hostID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(hostID).collection(FirestorePaths.friendNotePrompts)
    }

    func listenToNotes(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendNote], Error>) -> Void
    ) -> RepositoryListener {
        // Ordered server-side so the limit keeps the newest; `sortedByDate()` still runs since a note with no server timestamp sorts last here and belongs first.
        let reg = notes(hostID)
            .order(by: "createdAt", descending: true)
            .limit(to: friendNotesFetchLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let notes: [FriendNote] = (snapshot?.documents ?? []).compactMap { doc in
                    do {
                        var note = try doc.data(as: FriendNote.self)
                        note.id = doc.documentID
                        return note
                    } catch {
                        Telemetry.decodeFailure(
                            collection: FirestorePaths.friendNotes,
                            documentID: doc.documentID,
                            error: error
                        )
                        return nil
                    }
                }
                handler(.success(notes.sortedByDate()))
            }
        return FirestoreListenerBox(reg)
    }

    func listenToPrompts(
        hostID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener {
        let reg = prompts(hostID).addSnapshotListener { snapshot, error in
            if let error { handler(.failure(error)); return }
            handler(.success(Set((snapshot?.documents ?? []).map(\.documentID))))
        }
        return FirestoreListenerBox(reg)
    }

    @discardableResult
    func createNote(hostID: String, _ note: FriendNote) async throws -> String {
        let ref = notes(hostID).document()
        try await withRetry {
            try ref.setData(from: note)
        }
        return ref.documentID
    }

    func updateNote(hostID: String, noteID: String, text: String, stayRequestID: String?) async throws {
        try await withRetry {
            // A cleared stay link is removed, not written as null, as for review comments (an absent key is what nil encodes to).
            let stay: Any = stayRequestID.map { $0 as Any } ?? FieldValue.delete()
            try await notes(hostID).document(noteID).updateData([
                "text": text,
                "stayRequestID": stay,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func deleteNote(hostID: String, noteID: String) async throws {
        try await withRetry {
            try await notes(hostID).document(noteID).delete()
        }
    }

    func markPromptSeen(hostID: String, stayRequestID: String) async throws {
        try await withRetry {
            try await prompts(hostID).document(stayRequestID).setData([
                "dismissedAt": FieldValue.serverTimestamp()
            ])
        }
    }
}

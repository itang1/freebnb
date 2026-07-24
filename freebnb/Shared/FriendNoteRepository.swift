//
//  FriendNoteRepository.swift
//  freebnb
//
//  Reads and writes for a host's private notes on their friends.
//
//  There is only one audience in this file, which is the difference between it
//  and `CircleRepository`: Circles has a host side and a guest side because a
//  guest legitimately needs the resolved policy. Nobody but the author ever
//  reads a note, so there is no second half here, no projection to publish, and
//  no fan-out to keep in step. If a "guest side" ever appears below, something
//  has gone wrong with the feature.
//
//  One live listener covers the host's whole set rather than one per friend
//  viewed: notes are few, the friend screen and the post-stay prompt both need
//  them, and a per-friend query would need a composite index to buy nothing.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation

/// Enough that no real host reaches it, and low enough that a runaway client
/// can't quietly pull an unbounded collection down onto the device.
private let friendNotesFetchLimit = 1000

protocol FriendNoteRepository: Sendable {
    /// Every note this host has written, across all their friends, newest first.
    func listenToNotes(
        hostID: String,
        handler: @escaping @Sendable (Result<[FriendNote], Error>) -> Void
    ) -> RepositoryListener

    /// Which stays this host has already been asked about, so the post-stay
    /// prompt asks once and then stops.
    func listenToPrompts(
        hostID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener

    /// Writes a new note and returns its id.
    @discardableResult
    func createNote(hostID: String, _ note: FriendNote) async throws -> String
    /// Revises an existing note's text and stay link. Never its subject: the
    /// rules refuse a note re-pointed at a different person, and so does this.
    func updateNote(hostID: String, noteID: String, text: String, stayRequestID: String?) async throws
    func deleteNote(hostID: String, noteID: String) async throws

    /// Marks the post-stay prompt for one stay as dealt with, whether the host
    /// wrote something or waved it off. The two are the same fact here: they
    /// were asked, and they answered.
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
        // Ordered server-side so the limit takes the newest notes rather than an
        // arbitrary thousand; `sortedByDate()` still runs on the way out, because
        // a note whose server timestamp hasn't landed yet sorts last here and
        // belongs first.
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
            // A cleared stay link is removed rather than written as null, the
            // same way a cleared review comment is: an absent key is what the
            // encoder produces for nil everywhere else in this codebase.
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

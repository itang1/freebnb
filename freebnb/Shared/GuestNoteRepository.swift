//
//  GuestNoteRepository.swift
//  freebnb
//
//  Reads and writes for a guest's private notes on hosts and listings. One audience, as in
//  `FriendNoteRepository`: only the author reads a note, so there's no projection or
//  fan-out, and a "host side" appearing below would mean something went wrong. One live
//  listener covers the whole set, since notes are few and per-subject queries need a
//  composite index for nothing.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation

/// High enough that no real guest reaches it, low enough that a runaway client can't pull an unbounded collection.
private let guestNotesFetchLimit = 1000

protocol GuestNoteRepository: Sendable {
    /// Every note this guest wrote, across hosts and listings, newest first.
    func listenToNotes(
        guestID: String,
        handler: @escaping @Sendable (Result<[GuestNote], Error>) -> Void
    ) -> RepositoryListener

    /// Which trips this guest was already asked about, so the post-trip prompt asks once.
    func listenToPrompts(
        guestID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener

    /// Writes a new note and returns its id.
    @discardableResult
    func createNote(guestID: String, _ note: GuestNote) async throws -> String
    /// Revises a note's text and stay link, never its subject (the rules refuse a re-pointed note).
    func updateNote(guestID: String, noteID: String, text: String, stayRequestID: String?) async throws
    func deleteNote(guestID: String, noteID: String) async throws

    /// Marks one stay's post-trip prompt dealt with, whether the guest wrote or waved it off: they were asked
    /// and answered.
    func markPromptSeen(guestID: String, stayRequestID: String) async throws
}

struct FirestoreGuestNoteRepository: GuestNoteRepository {
    private let db: Firestore
    init(db: Firestore = .firestore()) { self.db = db }

    private func notes(_ guestID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(guestID).collection(FirestorePaths.guestNotes)
    }

    private func prompts(_ guestID: String) -> CollectionReference {
        db.collection(FirestorePaths.users).document(guestID).collection(FirestorePaths.guestNotePrompts)
    }

    func listenToNotes(
        guestID: String,
        handler: @escaping @Sendable (Result<[GuestNote], Error>) -> Void
    ) -> RepositoryListener {
        // Ordered server-side so the limit keeps the newest; `sortedByDate()` still runs since a note with no
        // server timestamp sorts last here and belongs first.
        let reg = notes(guestID)
            .order(by: "createdAt", descending: true)
            .limit(to: guestNotesFetchLimit)
            .addSnapshotListener { snapshot, error in
                if let error { handler(.failure(error)); return }
                let notes: [GuestNote] = (snapshot?.documents ?? []).compactMap { doc in
                    do {
                        var note = try doc.data(as: GuestNote.self)
                        note.id = doc.documentID
                        return note
                    } catch {
                        Telemetry.decodeFailure(
                            collection: FirestorePaths.guestNotes,
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
        guestID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener {
        let reg = prompts(guestID).addSnapshotListener { snapshot, error in
            if let error { handler(.failure(error)); return }
            handler(.success(Set((snapshot?.documents ?? []).map(\.documentID))))
        }
        return FirestoreListenerBox(reg)
    }

    @discardableResult
    func createNote(guestID: String, _ note: GuestNote) async throws -> String {
        let ref = notes(guestID).document()
        try await withRetry {
            try ref.setData(from: note)
        }
        return ref.documentID
    }

    func updateNote(guestID: String, noteID: String, text: String, stayRequestID: String?) async throws {
        try await withRetry {
            // A cleared stay link is removed, not written as null, as for friend notes (an absent key is what
            // nil encodes to).
            let stay: Any = stayRequestID.map { $0 as Any } ?? FieldValue.delete()
            try await notes(guestID).document(noteID).updateData([
                "text": text,
                "stayRequestID": stay,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
    }

    func deleteNote(guestID: String, noteID: String) async throws {
        try await withRetry {
            try await notes(guestID).document(noteID).delete()
        }
    }

    func markPromptSeen(guestID: String, stayRequestID: String) async throws {
        try await withRetry {
            try await prompts(guestID).document(stayRequestID).setData([
                "dismissedAt": FieldValue.serverTimestamp()
            ])
        }
    }
}

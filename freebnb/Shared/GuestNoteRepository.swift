//
//  GuestNoteRepository.swift
//  freebnb
//
//  Reads and writes for a guest's private notes on hosts and listings.
//
//  There is only one audience in this file, exactly as in `FriendNoteRepository`:
//  nobody but the author ever reads a note, so there is no second half here, no
//  projection to publish, and no fan-out to keep in step. If a "host side" or a
//  "listing side" ever appears below, something has gone wrong with the feature.
//
//  One live listener covers the guest's whole set rather than one per host or
//  listing viewed: notes are few, the profile, the listing page, and the
//  post-trip prompt all need them, and a per-subject query would need a composite
//  index to buy nothing.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation

/// Enough that no real guest reaches it, and low enough that a runaway client
/// can't quietly pull an unbounded collection down onto the device.
private let guestNotesFetchLimit = 1000

protocol GuestNoteRepository: Sendable {
    /// Every note this guest has written, across all hosts and listings, newest
    /// first.
    func listenToNotes(
        guestID: String,
        handler: @escaping @Sendable (Result<[GuestNote], Error>) -> Void
    ) -> RepositoryListener

    /// Which trips this guest has already been asked about, so the post-trip
    /// prompt asks once and then stops.
    func listenToPrompts(
        guestID: String,
        handler: @escaping @Sendable (Result<Set<String>, Error>) -> Void
    ) -> RepositoryListener

    /// Writes a new note and returns its id.
    @discardableResult
    func createNote(guestID: String, _ note: GuestNote) async throws -> String
    /// Revises an existing note's text and stay link. Never its subject: the
    /// rules refuse a note re-pointed at a different host or listing, and so does
    /// this.
    func updateNote(guestID: String, noteID: String, text: String, stayRequestID: String?) async throws
    func deleteNote(guestID: String, noteID: String) async throws

    /// Marks the post-trip prompt for one stay as dealt with, whether the guest
    /// wrote something or waved it off. The two are the same fact here: they were
    /// asked, and they answered.
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
        // Ordered server-side so the limit takes the newest notes rather than an
        // arbitrary thousand; `sortedByDate()` still runs on the way out, because
        // a note whose server timestamp hasn't landed yet sorts last here and
        // belongs first.
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
            // A cleared stay link is removed rather than written as null, the
            // same way a cleared friend note's is: an absent key is what the
            // encoder produces for nil everywhere else in this codebase.
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

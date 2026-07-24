//
//  FriendNoteStore.swift
//  freebnb
//
//  The host's own notes on their friends. Host-side only, in the strong sense:
//  no screen a guest can reach touches this store, and there is no derived
//  value here that any other user's device could observe.
//
//  What this store deliberately does not do is as much of the design as what it
//  does. It does not count notes into a score, does not expose "how many notes
//  about X" to anything that ranks or sorts friends, does not tell the friend
//  anything, and does not touch `CircleStore`. A note is something the host
//  reads and then decides for themselves; the moment it feeds a number, it has
//  become the rating system this feature exists instead of.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

@MainActor
@Observable
final class FriendNoteStore {
    /// Every note this host has written, newest first, across all friends.
    private(set) var notes: [FriendNote] = []
    /// Stay ids whose post-stay prompt the host has already answered or waved
    /// off.
    private(set) var seenPrompts: Set<String> = []
    private(set) var listenerError: String?
    /// False until the notes listener has delivered a first snapshot. The
    /// post-stay prompt waits on it, so a host isn't asked about a stay they
    /// already wrote a note for while that note is still in flight.
    private(set) var hasLoaded = false

    @ObservationIgnored private let repository: FriendNoteRepository
    @ObservationIgnored nonisolated(unsafe) private var notesListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var promptsListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var hostID: String = ""
    @ObservationIgnored private let log = AppLog.logger("friendNotes")

    init(repository: FriendNoteRepository = FirestoreFriendNoteRepository()) {
        self.repository = repository
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.isAnonymous == false ? user?.uid : nil
            Task { @MainActor in self?.restartListeners(userID: uid) }
        }
    }

    deinit {
        notesListener?.cancel()
        promptsListener?.cancel()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Derived views

    /// The notes about one friend, newest first. The only accessor any screen
    /// needs, and the only shape a note is ever read in.
    func notes(about friendID: String) -> [FriendNote] {
        notes.about(friendID)
    }

    /// The most recent note about one friend, for the one-line preview on their
    /// screen. Nil when there are none.
    func mostRecentNote(about friendID: String) -> FriendNote? {
        notes(about: friendID).first
    }

    /// Whether this host has already written something about `stayRequestID`.
    /// Used only to stop asking twice — never to mark a stay as "reviewed", and
    /// never surfaced to the other party.
    func hasNote(forStayRequestID stayRequestID: String) -> Bool {
        notes.contains { $0.stayRequestID == stayRequestID }
    }

    /// Whether the lightweight post-stay prompt still has anything to ask about
    /// this stay. Once the host writes a note or waves the prompt off, it is
    /// done for good.
    func shouldPrompt(forStayRequestID stayRequestID: String) -> Bool {
        hasLoaded
            && !seenPrompts.contains(stayRequestID)
            && !hasNote(forStayRequestID: stayRequestID)
    }

    // MARK: - Listeners

    private func restartListeners(userID: String?) {
        notesListener?.cancel(); notesListener = nil
        promptsListener?.cancel(); promptsListener = nil
        notes = []
        seenPrompts = []
        hasLoaded = false
        hostID = userID ?? ""
        guard let userID else { return }

        notesListener = repository.listenToNotes(hostID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let notes):
                    self.notes = notes
                    self.listenerError = nil
                case .failure(let error):
                    // Never logs a note's text or its subject: the log is the one
                    // place a private note could leak to somewhere the rules
                    // don't reach.
                    self.log.error("notes listener: \(error.localizedDescription, privacy: .public)")
                    self.listenerError = error.localizedDescription
                }
                self.hasLoaded = true
            }
        }

        promptsListener = repository.listenToPrompts(hostID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .success(let ids) = result { self.seenPrompts = ids }
            }
        }
    }

    // MARK: - Actions

    /// Writes a note about a friend. `stayRequestID` is context, not a
    /// requirement: a host noticing something in March should not have to find a
    /// visit to file it under.
    func addNote(about friendID: String, text: String, stayRequestID: String? = nil) async throws {
        guard !hostID.isEmpty, friendID != hostID, let body = FriendNote.normalized(text) else { return }
        try await repository.createNote(
            hostID: hostID,
            FriendNote(subjectUserID: friendID, text: body, stayRequestID: stayRequestID)
        )
        // Writing about a stay answers that stay's prompt, so it never comes
        // back. Best-effort: a failure here costs one redundant prompt, which is
        // not worth failing the note the host actually wrote.
        if let stayRequestID {
            try? await repository.markPromptSeen(hostID: hostID, stayRequestID: stayRequestID)
        }
    }

    func updateNote(_ note: FriendNote, text: String) async throws {
        guard !hostID.isEmpty, let id = note.id, let body = FriendNote.normalized(text) else { return }
        guard body != note.text else { return }
        try await repository.updateNote(
            hostID: hostID,
            noteID: id,
            text: body,
            stayRequestID: note.stayRequestID
        )
    }

    func deleteNote(_ note: FriendNote) async throws {
        guard !hostID.isEmpty, let id = note.id else { return }
        try await repository.deleteNote(hostID: hostID, noteID: id)
    }

    /// Waves off the post-stay prompt for one stay. Not a decision about the
    /// friend and not recorded as one — it means "don't ask me about this stay
    /// again", and the host can still add a note from that friend's screen
    /// whenever they like.
    func dismissPrompt(forStayRequestID stayRequestID: String) async {
        guard !hostID.isEmpty else { return }
        // Optimistic, so the row leaves under the tap rather than after a round
        // trip. The listener confirms it a moment later.
        seenPrompts.insert(stayRequestID)
        do { try await repository.markPromptSeen(hostID: hostID, stayRequestID: stayRequestID) }
        catch { log.error("dismiss note prompt: \(error.localizedDescription, privacy: .public)") }
    }
}

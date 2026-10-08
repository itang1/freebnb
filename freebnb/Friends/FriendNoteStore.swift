//
//  FriendNoteStore.swift
//  freebnb
//
//  The host's own notes on friends. Host-side only: no guest-reachable screen touches
//  this store and nothing derived is observable from another device. It doesn't count
//  notes into a score, expose counts to anything that ranks friends, tell the friend,
//  or touch `CircleStore`; a note that feeds a number becomes the rating system this feature replaces.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

@MainActor
@Observable
final class FriendNoteStore {
    /// Every note this host wrote, newest first, across all friends.
    private(set) var notes: [FriendNote] = []
    /// Stay ids whose post-stay prompt was answered or waved off.
    private(set) var seenPrompts: Set<String> = []
    private(set) var listenerError: String?
    /// False until the first notes snapshot; the prompt waits on it so a host isn't asked about a stay
    /// they've already noted.
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

    /// The notes about one friend, newest first; the only shape a note is read in.
    func notes(about friendID: String) -> [FriendNote] {
        notes.about(friendID)
    }

    /// The most recent note about one friend, for their one-line preview; nil when none.
    func mostRecentNote(about friendID: String) -> FriendNote? {
        notes(about: friendID).first
    }

    /// Whether this host already wrote something about `stayRequestID`; only to avoid asking twice, never
    /// surfaced.
    func hasNote(forStayRequestID stayRequestID: String) -> Bool {
        notes.contains { $0.stayRequestID == stayRequestID }
    }

    /// Whether the post-stay prompt still has anything to ask; done for good once a note is written or waved off.
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
                    // Never logs a note's text or subject: the log is the one place a private note could leak.
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

    /// Writes a note about a friend. `stayRequestID` is context, not required.
    func addNote(about friendID: String, text: String, stayRequestID: String? = nil) async throws {
        guard !hostID.isEmpty, friendID != hostID, let body = FriendNote.normalized(text) else { return }
        try await repository.createNote(
            hostID: hostID,
            FriendNote(subjectUserID: friendID, text: body, stayRequestID: stayRequestID)
        )
        // Writing answers the stay's prompt for good; best-effort, since failure costs only a redundant prompt.
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

    /// Waves off the post-stay prompt for one stay ("don't ask again"), not a judgement of the friend; notes
    /// stay writable from their screen.
    func dismissPrompt(forStayRequestID stayRequestID: String) async {
        guard !hostID.isEmpty else { return }
        // Optimistic, so the row leaves under the tap; the listener confirms.
        seenPrompts.insert(stayRequestID)
        do { try await repository.markPromptSeen(hostID: hostID, stayRequestID: stayRequestID) }
        catch { log.error("dismiss note prompt: \(error.localizedDescription, privacy: .public)") }
    }
}

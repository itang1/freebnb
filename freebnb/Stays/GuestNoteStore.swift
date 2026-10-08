//
//  GuestNoteStore.swift
//  freebnb
//
//  The guest's own notes on hosts and listings. Guest-side only: no screen the host can
//  reach touches this store and nothing derived is observable from another device.
//  As in `FriendNoteStore`, what it doesn't do is part of the design: no scores, no
//  "notes about this host" count for ranking, nothing told to the host, nothing fed to
//  a report.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

@MainActor
@Observable
final class GuestNoteStore {
    /// Every note this guest wrote, newest first, across all hosts and listings.
    private(set) var notes: [GuestNote] = []
    /// Stay ids whose post-trip prompt was answered or waved off.
    private(set) var seenPrompts: Set<String> = []
    private(set) var listenerError: String?
    /// False until the first notes snapshot; the prompt waits on it so a guest isn't asked about a trip they've already noted.
    private(set) var hasLoaded = false

    @ObservationIgnored private let repository: GuestNoteRepository
    @ObservationIgnored nonisolated(unsafe) private var notesListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var promptsListener: RepositoryListener?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var guestID: String = ""
    @ObservationIgnored private let log = AppLog.logger("guestNotes")

    init(repository: GuestNoteRepository = FirestoreGuestNoteRepository()) {
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

    /// The notes about one host or listing, newest first; the only shape a note is read in.
    func notes(about type: GuestNoteSubjectType, _ subjectID: String) -> [GuestNote] {
        notes.about(type, subjectID)
    }

    /// The most recent note about one subject, for its one-line preview; nil when none.
    func mostRecentNote(about type: GuestNoteSubjectType, _ subjectID: String) -> GuestNote? {
        notes(about: type, subjectID).first
    }

    /// Whether this guest already wrote something about `stayRequestID`; only to avoid asking twice, never surfaced.
    func hasNote(forStayRequestID stayRequestID: String) -> Bool {
        notes.contains { $0.stayRequestID == stayRequestID }
    }

    /// Whether the post-trip prompt still has anything to ask about this stay; done for good once a note is written or waved off.
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
        guestID = userID ?? ""
        guard let userID else { return }

        notesListener = repository.listenToNotes(guestID: userID) { [weak self] result in
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

        promptsListener = repository.listenToPrompts(guestID: userID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .success(let ids) = result { self.seenPrompts = ids }
            }
        }
    }

    // MARK: - Actions

    /// Writes a note about a host or listing. `stayRequestID` is context, not required.
    /// A `host` note about oneself is guarded here too (the composer and rules refuse it).
    func addNote(
        about type: GuestNoteSubjectType,
        _ subjectID: String,
        text: String,
        stayRequestID: String? = nil
    ) async throws {
        guard !guestID.isEmpty, !subjectID.isEmpty else { return }
        guard !(type == .host && subjectID == guestID) else { return }
        guard let body = GuestNote.normalized(text) else { return }
        try await repository.createNote(
            guestID: guestID,
            GuestNote(subjectType: type, subjectID: subjectID, text: body, stayRequestID: stayRequestID)
        )
        // Writing answers the trip's prompt for good; best-effort, since failure costs only a redundant prompt.
        if let stayRequestID {
            try? await repository.markPromptSeen(guestID: guestID, stayRequestID: stayRequestID)
        }
    }

    func updateNote(_ note: GuestNote, text: String) async throws {
        guard !guestID.isEmpty, let id = note.id, let body = GuestNote.normalized(text) else { return }
        guard body != note.text else { return }
        try await repository.updateNote(
            guestID: guestID,
            noteID: id,
            text: body,
            stayRequestID: note.stayRequestID
        )
    }

    func deleteNote(_ note: GuestNote) async throws {
        guard !guestID.isEmpty, let id = note.id else { return }
        try await repository.deleteNote(guestID: guestID, noteID: id)
    }

    /// Waves off the post-trip prompt for one stay ("don't ask again"), not a judgement of the host; notes stay writable elsewhere.
    func dismissPrompt(forStayRequestID stayRequestID: String) async {
        guard !guestID.isEmpty else { return }
        // Optimistic, so the row leaves under the tap; the listener confirms.
        seenPrompts.insert(stayRequestID)
        do { try await repository.markPromptSeen(guestID: guestID, stayRequestID: stayRequestID) }
        catch { log.error("dismiss note prompt: \(error.localizedDescription, privacy: .public)") }
    }
}

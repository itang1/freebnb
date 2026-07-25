//
//  GuestNoteStore.swift
//  freebnb
//
//  The guest's own notes on the hosts they stay with and the listings they
//  consider. Guest-side only, in the strong sense: no screen the host can reach
//  touches this store, and there is no derived value here that any other user's
//  device could observe.
//
//  What this store deliberately does not do is as much of the design as what it
//  does, exactly as in `FriendNoteStore`. It does not count notes into a score,
//  does not expose "how many notes about this host" to anything that ranks or
//  sorts, does not tell the host anything, and never feeds a report. A note is
//  something the guest reads and then decides for themselves; the moment it feeds
//  a number or reaches a moderator, it has become something this feature exists
//  instead of.
//

import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import os

@MainActor
@Observable
final class GuestNoteStore {
    /// Every note this guest has written, newest first, across all hosts and
    /// listings.
    private(set) var notes: [GuestNote] = []
    /// Stay ids whose post-trip prompt the guest has already answered or waved
    /// off.
    private(set) var seenPrompts: Set<String> = []
    private(set) var listenerError: String?
    /// False until the notes listener has delivered a first snapshot. The
    /// post-trip prompt waits on it, so a guest isn't asked about a trip they
    /// already wrote a note for while that note is still in flight.
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

    /// The notes about one subject — a host or a listing — newest first. The
    /// only accessor any screen needs, and the only shape a note is ever read in.
    func notes(about type: GuestNoteSubjectType, _ subjectID: String) -> [GuestNote] {
        notes.about(type, subjectID)
    }

    /// The most recent note about one subject, for the one-line preview on its
    /// screen. Nil when there are none.
    func mostRecentNote(about type: GuestNoteSubjectType, _ subjectID: String) -> GuestNote? {
        notes(about: type, subjectID).first
    }

    /// Whether this guest has already written something about `stayRequestID`.
    /// Used only to stop asking twice — never to mark a trip as "reviewed", and
    /// never surfaced to the other party.
    func hasNote(forStayRequestID stayRequestID: String) -> Bool {
        notes.contains { $0.stayRequestID == stayRequestID }
    }

    /// Whether the lightweight post-trip prompt still has anything to ask about
    /// this stay. Once the guest writes a note or waves the prompt off, it is
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
                    // Never logs a note's text or its subject: the log is the one
                    // place a private note could leak to somewhere the rules
                    // don't reach.
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

    /// Writes a note about a host or a listing. `stayRequestID` is context, not a
    /// requirement: a guest noticing something about a place they haven't booked
    /// should not have to find a visit to file it under.
    ///
    /// A guest never keeps a `host` note about themselves — the composer never
    /// offers it, and the rules refuse it — so that one case is guarded here too.
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
        // Writing about a trip answers that trip's prompt, so it never comes
        // back. Best-effort: a failure here costs one redundant prompt, which is
        // not worth failing the note the guest actually wrote.
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

    /// Waves off the post-trip prompt for one stay. Not a decision about the host
    /// and not recorded as one — it means "don't ask me about this trip again",
    /// and the guest can still add a note from the host's or the listing's screen
    /// whenever they like.
    func dismissPrompt(forStayRequestID stayRequestID: String) async {
        guard !guestID.isEmpty else { return }
        // Optimistic, so the row leaves under the tap rather than after a round
        // trip. The listener confirms it a moment later.
        seenPrompts.insert(stayRequestID)
        do { try await repository.markPromptSeen(guestID: guestID, stayRequestID: stayRequestID) }
        catch { log.error("dismiss note prompt: \(error.localizedDescription, privacy: .public)") }
    }
}

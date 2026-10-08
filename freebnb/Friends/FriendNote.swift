//
//  FriendNote.swift
//  freebnb
//
//  A host's private note about one friend. Stored at
//  `users/{hostID}/friendNotes/{noteID}`, readable by that host alone. The host
//  is the path; nothing is denormalized, projected or scored. Enforcement is the
//  `friendNotes` block in firestore.rules; this file must agree.
//
//  Notes are reference material for a host's judgement, never an input to it.
//

import FirebaseFirestore
import Foundation

struct FriendNote: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried beside the document like `FriendCircle.id`
    /// (`@DocumentID` discards locally set values). The repository stamps it.
    var id: String?

    /// The friend this note is about. Immutable; the rules pin it on update.
    let subjectUserID: String

    var text: String

    /// The stay this came from, if any. Nil is ordinary: a host can note something without a visit.
    var stayRequestID: String?

    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it isn't encoded.
    enum CodingKeys: String, CodingKey {
        case subjectUserID, text, stayRequestID, createdAt, updatedAt
    }

    /// Matches the rules' cap, so overlong notes are a composer error rather than a permission denial.
    static let maxLength = 2000

    init(
        id: String? = nil,
        subjectUserID: String,
        text: String,
        stayRequestID: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.subjectUserID = subjectUserID
        self.text = text
        self.stayRequestID = stayRequestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether the note was edited since written. Both timestamps are server-stamped, so allow slack.
    var wasEdited: Bool {
        guard let createdAt, let updatedAt else { return false }
        return updatedAt.timeIntervalSince(createdAt) > 1
    }

    static func == (lhs: FriendNote, rhs: FriendNote) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Validation

extension FriendNote {
    /// The text as stored: trimmed and cut to the cap. Nil when empty, which disables Save.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

// MARK: - The post-stay prompt

/// When the app offers a host the optional add-a-note moment after a stay. Pure
/// and separate from the view since the judgement call is how widely to ask: too
/// wide and an established host meets a wall of prompts about old stays.
enum FriendNotePrompt {
    /// How long after a stay ends the prompt is still worth offering: two weeks.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether `stay` should be offered to `hostID` as a note moment.
    /// `isSettled` (already asked or written) comes from the store, which knows
    /// notes; nothing about the guest is consulted.
    static func shouldOffer(
        _ stay: StayRequest,
        hostID: String,
        isSettled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !hostID.isEmpty, stay.hostUserID == hostID else { return false }
        guard stay.status == .completed, !isSettled else { return false }
        // `completedAt` may be missing for a swept stay, so checkout stands in: did this end recently?
        let endedAt = stay.completedAt ?? stay.checkOut
        return endedAt >= now.addingTimeInterval(-window)
    }
}

// MARK: - Derived views

extension [FriendNote] {
    /// Newest first; a note awaiting its server timestamp floats to the top, as in `[Review]`.
    func sortedByDate() -> [FriendNote] {
        sorted {
            switch ($0.createdAt, $1.createdAt) {
            case (nil, nil): return false
            case (nil, _):   return true   // pending write floats up
            case (_, nil):   return false
            case (let a, let b):
                guard let a, let b else { return false }
                return a > b
            }
        }
    }

    /// The notes about one friend, newest first.
    func about(_ subjectUserID: String) -> [FriendNote] {
        filter { $0.subjectUserID == subjectUserID }.sortedByDate()
    }
}

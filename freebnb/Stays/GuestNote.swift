//
//  GuestNote.swift
//  freebnb
//
//  A guest's private note about a host or a listing. Stored at
//  `users/{guestID}/guestNotes/{noteID}`, readable by that guest alone.
//
//  The counterpart to `FriendNote`, but reference material for the guest only:
//  nothing is denormalized, projected, scored or sent to moderation (reporting is
//  separate). Enforcement is the `guestNotes` block in firestore.rules; this file
//  must agree. The subject is a host or a listing.
//

import FirebaseFirestore
import Foundation

/// What a guest note is about: a host (user) or a listing (home). `subjectID` is its
/// document id, and the rules pin the pair so an edit can't re-file the note.
enum GuestNoteSubjectType: String, Codable, Hashable, Sendable, CaseIterable {
    case host
    case listing
}

struct GuestNote: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried beside the document like `FriendNote.id`
    /// (`@DocumentID` discards locally set values). The repository stamps it.
    var id: String?

    /// Whether the note is about a host or a listing. Immutable; pinned by the rules.
    let subjectType: GuestNoteSubjectType

    /// The host's uid or the listing's id per `subjectType`. Immutable.
    let subjectID: String

    var text: String

    /// The stay this came from, if any. Nil is ordinary: a guest can note a place they haven't visited.
    var stayRequestID: String?

    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it isn't encoded.
    enum CodingKeys: String, CodingKey {
        case subjectType, subjectID, text, stayRequestID, createdAt, updatedAt
    }

    /// Matches the rules' cap and `FriendNote.maxLength`, so overlong notes are a composer error.
    static let maxLength = 2000

    init(
        id: String? = nil,
        subjectType: GuestNoteSubjectType,
        subjectID: String,
        text: String,
        stayRequestID: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.subjectType = subjectType
        self.subjectID = subjectID
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

    static func == (lhs: GuestNote, rhs: GuestNote) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Validation

extension GuestNote {
    /// The text as stored: trimmed and cut to the cap. Nil when empty, which disables Save.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

// MARK: - The post-stay prompt

/// When the app offers a guest the optional add-a-note moment after a trip; the
/// guest-side mirror of `FriendNotePrompt`. Pure and separate from the view,
/// since the judgement call is which trips are worth asking about.
enum GuestNotePrompt {
    /// How long after a trip ends the prompt is still worth offering: two weeks, as on the host side.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether `stay` should be offered to `guestID` as a note moment.
    /// `isSettled` (already asked or written) comes from the store, which knows
    /// notes; nothing about the host is consulted.
    static func shouldOffer(
        _ stay: StayRequest,
        guestID: String,
        isSettled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !guestID.isEmpty, stay.guestUserID == guestID else { return false }
        guard stay.status == .completed, !isSettled else { return false }
        // `completedAt` may be missing for a swept stay, so checkout stands in: did this end recently?
        let endedAt = stay.completedAt ?? stay.checkOut
        return endedAt >= now.addingTimeInterval(-window)
    }
}

// MARK: - Derived views

extension [GuestNote] {
    /// Newest first; a note awaiting its server timestamp floats to the top, as in `[FriendNote]`.
    func sortedByDate() -> [GuestNote] {
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

    /// Notes about one host or listing, newest first. Both identity halves are matched so ids can't collide.
    func about(_ type: GuestNoteSubjectType, _ subjectID: String) -> [GuestNote] {
        filter { $0.subjectType == type && $0.subjectID == subjectID }.sortedByDate()
    }
}

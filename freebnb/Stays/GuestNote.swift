//
//  GuestNote.swift
//  freebnb
//
//  A guest's private note about a host or a listing: what they'd write on the
//  back of their own index card after a stay, and never show anybody. Stored at
//  `users/{guestID}/guestNotes/{noteID}`, readable by that guest and by nobody
//  else, ever.
//
//  This is the symmetric counterpart to `FriendNote`, which lets a host keep a
//  private read on a friend. That one protects a host from a repeat bad guest; a
//  note here does nothing to the person it is about and is not meant to — it is
//  reference material for the guest alone, so a guest who had a rough stay has
//  their own record too. The guest is the path, not a field. Nothing here is
//  denormalized onto the host or the listing, projected for anyone to read,
//  counted into a score, or sent to a moderator: the app has a moderation queue
//  (`reports`), and reporting a host already lives on the profile and listing
//  pages, but a note is deliberately *not* that. See the `guestNotes` block in
//  firestore.rules, which is the enforcement; this file only has to agree.
//
//  Unlike a friend note, whose subject is always a person, a guest note points
//  at a host *or* a listing — the two things a guest forms an opinion about.
//

import FirebaseFirestore
import Foundation

/// What a guest note is about. A host (a user) or a listing (a home) — the
/// `subjectID` is that thing's document id, and `firestore.rules` pins the pair
/// so an edit can never quietly re-file a note from one onto the other.
enum GuestNoteSubjectType: String, Codable, Hashable, Sendable, CaseIterable {
    case host
    case listing
}

struct GuestNote: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried beside the document rather than in it, for the
    /// same reason as `FriendNote.id`: these are constructed locally before any
    /// document exists, and `@DocumentID` discards a value set that way. The
    /// repository stamps it from `documentID` on the way in.
    var id: String?

    /// Whether this note is about a host or a listing. Immutable once written —
    /// `firestore.rules` pins it on update, alongside `subjectID`.
    let subjectType: GuestNoteSubjectType

    /// The host's uid or the listing's id, depending on `subjectType`. Immutable
    /// once written, so a note can never be re-pointed at a different host or a
    /// different place while keeping its date.
    let subjectID: String

    var text: String

    /// The stay this note came out of, when it came out of one. Nil is the
    /// ordinary case and not a degraded one: a guest should be able to note
    /// something about a place they are still deciding on, with no visit yet to
    /// hang it on.
    var stayRequestID: String?

    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it is never encoded into the document.
    enum CodingKeys: String, CodingKey {
        case subjectType, subjectID, text, stayRequestID, createdAt, updatedAt
    }

    /// Matches the cap `firestore.rules` enforces, and mirrors
    /// `FriendNote.maxLength`: an over-long note should be a field error in the
    /// composer, not an opaque permission denial from the server.
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

    /// Whether this note has been edited since it was written. Both timestamps
    /// are server-stamped, and a create sets them in the same commit, so the
    /// comparison needs a little slack rather than an equality test.
    var wasEdited: Bool {
        guard let createdAt, let updatedAt else { return false }
        return updatedAt.timeIntervalSince(createdAt) > 1
    }

    static func == (lhs: GuestNote, rhs: GuestNote) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Validation

extension GuestNote {
    /// The text as it would be stored: trimmed, and cut to the cap the rules
    /// enforce. Returns nil when there is nothing left, which is what makes
    /// "save an empty note" a disabled button rather than a rejected write.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

// MARK: - The post-stay prompt

/// When the app offers a guest the optional add-a-note moment after a trip.
///
/// The mirror of `FriendNotePrompt`, from the other side of the same stay: that
/// one asks the host once a guest has left; this one asks the guest once their
/// trip is over. Pure and separate from the view for the same reason — the one
/// judgement call in the feature is which trips are worth being asked about, and
/// asking too widely greets an established traveler with a wall of prompts about
/// trips from two years ago the first time they open the new build.
enum GuestNotePrompt {
    /// How long after a trip ends the prompt is still worth offering. Two weeks,
    /// matching the host side: long enough to survive a traveler who doesn't open
    /// the app the day they get home, short enough that it is still about that
    /// trip.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether `stay` should be offered to `guestID` as a note moment.
    ///
    /// `isSettled` is the caller's answer to "have they already been asked, or
    /// already written something" — it lives in the store, which knows about
    /// notes, rather than here, which knows about time.
    ///
    /// Nothing about the *host* is consulted. There is no "difficult stay"
    /// heuristic and no reason to build one: which trips are worth remembering is
    /// exactly the judgement being left to the guest.
    static func shouldOffer(
        _ stay: StayRequest,
        guestID: String,
        isSettled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !guestID.isEmpty, stay.guestUserID == guestID else { return false }
        guard stay.status == .completed, !isSettled else { return false }
        // `completedAt` is set when either party closes the stay out; a stay
        // swept up by the nightly job may not carry one, so checkout stands in.
        // Either way the question is the same: did this end recently?
        let endedAt = stay.completedAt ?? stay.checkOut
        return endedAt >= now.addingTimeInterval(-window)
    }
}

// MARK: - Derived views

extension [GuestNote] {
    /// Newest first. A note still awaiting its server timestamp floats to the
    /// top so one just written appears immediately, matching `[FriendNote]`.
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

    /// The notes about one subject — a host or a listing — newest first. Both
    /// halves of the identity are matched, so a host's uid can never collide with
    /// a listing id that happens to share the same string.
    func about(_ type: GuestNoteSubjectType, _ subjectID: String) -> [GuestNote] {
        filter { $0.subjectType == type && $0.subjectID == subjectID }.sortedByDate()
    }
}

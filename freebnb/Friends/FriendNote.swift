//
//  FriendNote.swift
//  freebnb
//
//  A host's private note about one friend: what they'd write on the back of an
//  index card and never show anybody. Stored at
//  `users/{hostID}/friendNotes/{noteID}`, readable by that host and by nobody
//  else, ever.
//
//  The host is the path, not a field. Nothing here is denormalized onto the
//  friend, projected for anyone to read, or counted into a score — unlike a
//  circle's policy, which a guest legitimately needs the resolved half of, a
//  note has no audience but its author, so there is nothing to project. See the
//  `friendNotes` block in firestore.rules, which is the enforcement; this file
//  only has to agree with it.
//
//  Notes exist so a host can move somebody into a stricter circle for a reason
//  they can still remember in six months. They are reference material for that
//  judgement, never an input to it: nothing reads these to change a circle, and
//  nothing ever will.
//

import FirebaseFirestore
import Foundation

struct FriendNote: Identifiable, Codable, Hashable, Sendable {
    /// The document id, carried beside the document rather than in it, for the
    /// same reason as `FriendCircle.id`: these are constructed locally before any
    /// document exists, and `@DocumentID` discards a value that was set that way.
    /// The repository stamps it from `documentID` on the way in.
    var id: String?

    /// The friend this note is about. Immutable once written — `firestore.rules`
    /// pins it on update, so an edit cannot quietly re-file a note under a
    /// different person.
    let subjectUserID: String

    var text: String

    /// The stay this note came out of, when it came out of one. Nil is the
    /// ordinary case and not a degraded one: a host should be able to write down
    /// something they noticed without a visit to hang it on.
    var stayRequestID: String?

    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The id lives in the path, so it is never encoded into the document.
    enum CodingKeys: String, CodingKey {
        case subjectUserID, text, stayRequestID, createdAt, updatedAt
    }

    /// Matches the cap `firestore.rules` enforces, for the same reason
    /// `Review.commentMaxLength` does: an over-long note should be a field error
    /// in the composer, not an opaque permission denial from the server.
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

    /// Whether this note has been edited since it was written. Both timestamps
    /// are server-stamped, and a create sets them in the same commit, so the
    /// comparison needs a little slack rather than an equality test.
    var wasEdited: Bool {
        guard let createdAt, let updatedAt else { return false }
        return updatedAt.timeIntervalSince(createdAt) > 1
    }

    static func == (lhs: FriendNote, rhs: FriendNote) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Validation

extension FriendNote {
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

/// When the app offers a host the optional add-a-note moment after a stay.
///
/// Pure and separate from the view because it is the one piece of this feature
/// with a judgement call in it: ask too narrowly and the moment is missed, ask
/// too widely and an established host meets a wall of prompts about stays from
/// two years ago the first time they open the new build. A wall is a chore, and
/// a chore gets dismissed unread, which costs the feature the one moment it was
/// built for.
enum FriendNotePrompt {
    /// How long after a stay ends the prompt is still worth offering. Two weeks:
    /// long enough to survive a host who doesn't open the app the day their
    /// guest leaves, short enough that it is still about that visit.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether `stay` should be offered to `hostID` as a note moment.
    ///
    /// `isSettled` is the caller's answer to "have they already been asked, or
    /// already written something" — it lives in the store, which knows about
    /// notes, rather than here, which knows about time.
    ///
    /// Nothing about the *guest* is consulted. There is no "difficult stay"
    /// heuristic and no reason to build one: which visits are worth remembering
    /// is exactly the judgement being left to the host.
    static func shouldOffer(
        _ stay: StayRequest,
        hostID: String,
        isSettled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !hostID.isEmpty, stay.hostUserID == hostID else { return false }
        guard stay.status == .completed, !isSettled else { return false }
        // `completedAt` is set when either party closes the stay out; a stay
        // swept up by the nightly job may not carry one, so checkout stands in.
        // Either way the question is the same: did this end recently?
        let endedAt = stay.completedAt ?? stay.checkOut
        return endedAt >= now.addingTimeInterval(-window)
    }
}

// MARK: - Derived views

extension [FriendNote] {
    /// Newest first. A note still awaiting its server timestamp floats to the
    /// top so one just written appears immediately, matching `[Review]` and
    /// `[StayRequest]`.
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

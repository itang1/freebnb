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

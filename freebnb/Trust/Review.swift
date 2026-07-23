//
//  Review.swift
//  freebnb
//
//  Post-stay reviews and friend-written character references (feature 1).
//
//  Three documents, three visibilities:
//    - `reviews/{stayRequestID}_{authorUID}`  — public, one per person per stay.
//    - `reviews/{id}/private/feedback`        — the note only the two of them read.
//    - `references/{subjectUID}_{authorUID}`  — public, and only a friend may write one.
//
//  The deterministic ids are load-bearing: "exactly one review per person per
//  stay" is a rule on the document path, not a query the client could skip.
//

import FirebaseFirestore
import Foundation

/// Which side of a stay the review was written from. Determines whose profile
/// the review lands on, and what the reader is being told about.
enum ReviewRole: String, Codable, Hashable, CaseIterable, Sendable {
    case guestReviewingHost = "guestReviewingHost"
    case hostReviewingGuest = "hostReviewingGuest"

    var subjectNoun: String {
        switch self {
        case .guestReviewingHost: return "host"
        case .hostReviewingGuest: return "guest"
        }
    }

    /// What the public comment box is asking for.
    var prompt: String {
        switch self {
        case .guestReviewingHost: return "How was staying with your host?"
        case .hostReviewingGuest: return "How was hosting this guest?"
        }
    }
}

struct Review: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let stayRequestID: String
    let listingID: String
    let authorUserID: String
    /// The person being reviewed; their `trustStats` aggregate this.
    let subjectUserID: String
    let role: ReviewRole
    var rating: Int
    var publicComment: String?
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    /// The one legal document id for this (stay, author) pair. `firestore.rules`
    /// requires the written id to equal this, which is what makes a second review
    /// of the same stay an overwrite of the first rather than a new document.
    static func id(stayRequestID: String, authorUserID: String) -> String {
        "\(stayRequestID)_\(authorUserID)"
    }

    static let ratingRange = 1...5

    /// Matches the `publicComment` cap in `firestore.rules`, for the same reason
    /// `PrivateFeedback.maxLength` exists: an over-long comment should be a field
    /// error in the composer, not a permission denial from the server.
    static let commentMaxLength = 2000

    init(
        stayRequestID: String,
        listingID: String,
        authorUserID: String,
        subjectUserID: String,
        role: ReviewRole,
        rating: Int,
        publicComment: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = Self.id(stayRequestID: stayRequestID, authorUserID: authorUserID)
        self.stayRequestID = stayRequestID
        self.listingID = listingID
        self.authorUserID = authorUserID
        self.subjectUserID = subjectUserID
        self.role = role
        self.rating = rating.clamped(to: Self.ratingRange)
        self.publicComment = publicComment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func == (lhs: Review, rhs: Review) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The reviewer's private note to the person they reviewed: the thing you'd say
/// to someone's face but not on their profile. Stored under the review so it
/// inherits the review's authorship, and readable only by those two people.
struct PrivateFeedback: Codable, Hashable, Sendable {
    var text: String

    /// Matches the cap `firestore.rules` enforces on the feedback document. Kept
    /// here so the composer can refuse an over-long note as a field error; without
    /// it the write reached the server and came back as an opaque permission
    /// denial, which reads as "something broke" rather than "this is too long".
    static let maxLength = 2000
}

/// A character reference one friend writes for another, independent of any stay
/// (feature 1). The rules require an accepted `friendEdges` document between the
/// two, so a stranger cannot vouch for anyone.
struct CharacterReference: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let authorUserID: String
    let subjectUserID: String
    var text: String
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    static func id(subjectUserID: String, authorUserID: String) -> String {
        "\(subjectUserID)_\(authorUserID)"
    }

    static let maxLength = 2000

    init(
        authorUserID: String,
        subjectUserID: String,
        text: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = Self.id(subjectUserID: subjectUserID, authorUserID: authorUserID)
        self.authorUserID = authorUserID
        self.subjectUserID = subjectUserID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func == (lhs: CharacterReference, rhs: CharacterReference) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Derived views

extension [Review] {
    /// Newest first; a review still awaiting its server timestamp floats up so a
    /// just-written one appears immediately.
    func sortedByDate() -> [Review] {
        sorted {
            switch ($0.createdAt, $1.createdAt) {
            case (nil, nil): return false
            case (nil, _):   return true
            case (_, nil):   return false
            case (let a, let b):
                guard let a, let b else { return false }
                return a > b
            }
        }
    }

    /// Mean rating, or nil when empty. The server recomputes the authoritative
    /// copy into `trustStats`; this is for rendering a list you already hold.
    var averageRating: Double? {
        guard !isEmpty else { return nil }
        return Double(reduce(0) { $0 + $1.rating }) / Double(count)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

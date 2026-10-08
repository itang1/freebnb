//
//  Review.swift
//  freebnb
//
//  Post-stay reviews and friend-written character references. Three documents:
//    - `reviews/{stayRequestID}_{authorUID}`  public, one per person per stay.
//    - `reviews/{id}/private/feedback`        the note only the two of them read.
//    - `references/{subjectUID}_{authorUID}`  public; only a friend may write one.
//  The deterministic ids are load-bearing: "one review per person per stay" is a rule on the path.

import FirebaseFirestore
import Foundation

/// Which side of a stay the review was written from; decides whose profile it lands on.
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

    /// The one legal document id for this (stay, author) pair; the rules require it, so a second review overwrites the first.
    static func id(stayRequestID: String, authorUserID: String) -> String {
        "\(stayRequestID)_\(authorUserID)"
    }

    static let ratingRange = 1...5

    /// Matches the `publicComment` cap in `firestore.rules`, so an over-long comment is a field error, not a permission denial.
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

/// The reviewer's private note to the person reviewed, stored under the review and readable only by those two.
struct PrivateFeedback: Codable, Hashable, Sendable {
    var text: String

    /// Matches the cap `firestore.rules` enforces, so the composer refuses an over-long note instead of an opaque permission denial.
    static let maxLength = 2000
}

/// A character reference one friend writes for another, independent of any stay; the rules require an accepted friend edge.
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
    /// Newest first; a review awaiting its server timestamp floats up so a just-written one appears.
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

    /// Mean rating, or nil when empty; the server's `trustStats` is authoritative, this is for lists already held.
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

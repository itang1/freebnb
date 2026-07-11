//
//  FeedbackDraft.swift
//  freebnb
//
//  The in-app feedback composer's model (feature 43). A feedback note is a short,
//  categorized free-text message the user sends to the team; it lands in the
//  `feedback` collection, which only a moderator can read (see firestore.rules).
//  The validation here is the same shape the rules enforce, so a note the UI
//  accepts is a note the server accepts.
//

import Foundation

enum FeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    /// A suggestion or a feature request.
    case idea
    /// Something is broken or confusing.
    case problem
    /// The user just wants to say something nice.
    case praise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idea:    return "Idea"
        case .problem: return "Problem"
        case .praise:  return "Praise"
        }
    }

    var icon: String {
        switch self {
        case .idea:    return "lightbulb"
        case .problem: return "exclamationmark.bubble"
        case .praise:  return "heart"
        }
    }

    /// Placeholder shown in the composer, so the empty field already coaches the
    /// user toward a useful note.
    var prompt: String {
        switch self {
        case .idea:    return "What would make FreeBNB better?"
        case .problem: return "What went wrong, and where?"
        case .praise:  return "What did you enjoy?"
        }
    }
}

/// A feedback note being composed. Pure and `Equatable` so the composer's
/// enablement and counter derive from it and it is unit-testable without a view.
struct FeedbackDraft: Equatable, Sendable {
    var category: FeedbackCategory
    var message: String

    /// Kept in lockstep with the `feedback` create rule's `message.size() <= 2000`.
    static let maxLength = 2000

    init(category: FeedbackCategory = .idea, message: String = "") {
        self.category = category
        self.message = message
    }

    /// The message with surrounding whitespace removed, which is what gets sent
    /// and what the length checks below count.
    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters left before the cap. Goes negative once the user is over, so
    /// the composer can flag it in red without a second computation.
    var remainingCharacters: Int {
        Self.maxLength - trimmedMessage.count
    }

    /// A note is sendable when it has content and is within the cap. An
    /// all-whitespace note is empty after trimming and so is rejected here,
    /// exactly as the rules reject `size() == 0`.
    var isValid: Bool {
        let count = trimmedMessage.count
        return count > 0 && count <= Self.maxLength
    }
}

//
//  FeedbackDraft.swift
//  freebnb
//
//  The in-app feedback composer's model (feature 43). A feedback note is a short
//  free-text message the user sends to the team; it is delivered to the Google
//  Form in `FeedbackService`, whose responses feed the team's spreadsheet.
//

import Foundation

/// A feedback note being composed. Pure and `Equatable` so the composer's
/// enablement and counter derive from it and it is unit-testable without a view.
struct FeedbackDraft: Equatable, Sendable {
    var message: String

    /// A sane client-side length so the composer can show a counter and reject a
    /// runaway paste; the Form itself imposes no cap.
    static let maxLength = 2000

    init(message: String = "") {
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
    /// all-whitespace note is empty after trimming and so is rejected here.
    var isValid: Bool {
        let count = trimmedMessage.count
        return count > 0 && count <= Self.maxLength
    }
}

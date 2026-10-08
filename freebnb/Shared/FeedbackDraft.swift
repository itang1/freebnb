//
//  FeedbackDraft.swift
//  freebnb
//
//  The feedback composer's model: a short free-text note delivered to the Google Form in `FeedbackService`.
//

import Foundation

/// A feedback note being composed; pure and `Equatable` so enablement and counter derive from it without a view.
struct FeedbackDraft: Equatable, Sendable {
    var message: String

    /// A client-side length so the composer can show a counter and reject a runaway paste; the Form has no cap.
    static let maxLength = 2000

    init(message: String = "") {
        self.message = message
    }

    /// The message trimmed of surrounding whitespace, which is what's sent and counted.
    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters left before the cap; negative once over, so the composer can flag it red.
    var remainingCharacters: Int {
        Self.maxLength - trimmedMessage.count
    }

    /// Sendable when it has content within the cap; all-whitespace is empty after trimming.
    var isValid: Bool {
        let count = trimmedMessage.count
        return count > 0 && count <= Self.maxLength
    }
}

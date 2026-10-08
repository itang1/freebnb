//
//  ConversationStayContext.swift
//  freebnb
//
//  The stay chip on a conversation row: what, if anything, is going on between the two
//  people. Pure, so the rule for "currently going on" is testable without a store or view.
//

import Foundation

/// The one stay worth captioning a conversation with, and how to say it.
struct ConversationStayContext: Equatable {
    enum Kind: Equatable {
        /// This user owes the answer.
        case awaitingYou
        /// The other person owes the answer.
        case awaitingThem
        case underway
        case upcoming
    }

    let kind: Kind
    let dateRangeText: String

    /// Short enough for a row that already carries a name, a preview, and a time.
    var label: String {
        switch kind {
        case .awaitingYou:  return "Needs your answer · \(dateRangeText)"
        case .awaitingThem: return "Awaiting reply · \(dateRangeText)"
        case .underway:     return "Staying now · \(dateRangeText)"
        case .upcoming:     return "Confirmed · \(dateRangeText)"
        }
    }

    var systemImage: String {
        switch kind {
        case .awaitingYou:  return "exclamationmark.circle.fill"
        case .awaitingThem: return "clock"
        case .underway:     return "house.fill"
        case .upcoming:     return "checkmark.circle"
        }
    }

    /// Only the chip meaning "you are blocking this" earns a colour; coloured chips everywhere would flatten it.
    var isActionable: Bool { kind == .awaitingYou }
}

enum ConversationStay {
    /// The stay to caption a conversation with, or nil when nothing is live. A settled
    /// stay (finished or declined) is history. An accepted stay stops counting after
    /// checkout even though the document stays `accepted` until the nightly sweep. When
    /// several qualify the most urgent wins, in enum order: an answer you owe, then under way, then upcoming.
    static func context(
        between viewerID: String,
        and otherUserID: String,
        stays: [StayRequest],
        now: Date = Date()
    ) -> ConversationStayContext? {
        guard !viewerID.isEmpty, !otherUserID.isEmpty else { return nil }

        let shared = stays.filter { stay in
            let parties = [stay.hostUserID, stay.guestUserID]
            return parties.contains(viewerID) && parties.contains(otherUserID)
        }

        let candidates = shared.compactMap { stay -> ConversationStayContext? in
            switch stay.status {
            case .pending, .offered:
                let kind: ConversationStayContext.Kind =
                    stay.awaitsReply(from: viewerID) ? .awaitingYou : .awaitingThem
                return ConversationStayContext(kind: kind, dateRangeText: stay.dateRangeText)
            case .accepted:
                guard stay.checkOut >= now else { return nil }
                return ConversationStayContext(
                    kind: stay.isUnderway(now: now) ? .underway : .upcoming,
                    dateRangeText: stay.dateRangeText
                )
            case .declined, .cancelled, .completed:
                return nil
            }
        }

        return candidates.min { rank($0.kind) < rank($1.kind) }
    }

    private static func rank(_ kind: ConversationStayContext.Kind) -> Int {
        switch kind {
        case .awaitingYou:  return 0
        case .underway:     return 1
        case .upcoming:     return 2
        case .awaitingThem: return 3
        }
    }
}

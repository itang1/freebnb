//
//  ConversationStayContext.swift
//  freebnb
//
//  The stay chip on a conversation row: what, if anything, is currently going on
//  between the two people in a thread.
//
//  Most conversations in this app orbit a stay, and the list previously gave no
//  hint of it — a thread about a confirmed trip next week looked exactly like one
//  about nothing. This is the derivation behind that chip, kept pure so the rule
//  for "currently going on" is testable without a store or a view.
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

    /// Only the chip that means "you are blocking this" earns a colour; the rest
    /// are context, and a row full of coloured chips would flatten the one that
    /// actually wants acting on.
    var isActionable: Bool { kind == .awaitingYou }
}

enum ConversationStay {
    /// The stay to caption a conversation with, or nil when there is nothing
    /// live between these two.
    ///
    /// "Live" deliberately excludes a settled stay: a trip that finished, or a
    /// request that was declined, is history, and captioning a thread with it
    /// forever would turn the chip into decoration. An accepted stay stops
    /// counting once its checkout has passed, even though the document stays
    /// `accepted` until the nightly sweep completes it — otherwise a thread would
    /// claim a stay is "confirmed" for hours after the guest went home.
    ///
    /// When several qualify, the most urgent wins, in the order the enum is
    /// written: something you owe an answer on outranks a stay under way, which
    /// outranks one merely upcoming.
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

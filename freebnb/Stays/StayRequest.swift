//
//  StayRequest.swift
//  freebnb
//

import FirebaseFirestore
import Foundation

enum StayRequestStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case pending   = "pending"
    case offered   = "offered"
    case accepted  = "accepted"
    case completed = "completed"
    case declined  = "declined"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .offered:   return "Offered"
        case .accepted:  return "Accepted"
        case .completed: return "Completed"
        case .declined:  return "Declined"
        case .cancelled: return "Cancelled"
        }
    }

    /// Not yet resolved either way. An offer is active for the same reason a
    /// pending request is: nobody has said no, and the address grant that
    /// `updateStatus` withdraws on every inactive status must not be withdrawn
    /// from underneath it.
    var isActive: Bool { self == .pending || self == .offered || self == .accepted }

    /// Whether this is waiting on somebody's answer. The two awaiting statuses
    /// differ only in which side owes the reply — see `awaitingReply(from:)`.
    var isAwaitingReply: Bool { self == .pending || self == .offered }

    /// True for the statuses that mean the stay actually happened. `accepted`
    /// counts because a stay in progress has not been cancelled away.
    var didHappen: Bool { self == .accepted || self == .completed }
}

enum StayRequestRole: Sendable {
    case guest
    case host
}

/// Roughly when the guest expects to arrive, so the host can plan the handoff
/// (feature 20). Stored by raw value; the rules validate membership in this set.
enum ArrivalWindow: String, Codable, Hashable, CaseIterable, Sendable {
    case flexible  = "flexible"
    case morning   = "morning"
    case afternoon = "afternoon"
    case evening   = "evening"
    case lateNight = "lateNight"

    var displayName: String {
        switch self {
        case .flexible:  return "Flexible / not sure"
        case .morning:   return "Morning (8am–12pm)"
        case .afternoon: return "Afternoon (12–5pm)"
        case .evening:   return "Evening (5–9pm)"
        case .lateNight: return "Late (after 9pm)"
        }
    }

    /// Short form for compact request rows.
    var shortName: String {
        switch self {
        case .flexible:  return "Flexible arrival"
        case .morning:   return "Morning arrival"
        case .afternoon: return "Afternoon arrival"
        case .evening:   return "Evening arrival"
        case .lateNight: return "Late arrival"
        }
    }
}

enum StayRequestError: LocalizedError {
    case overlappingStay
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .overlappingStay:
            return "Those dates overlap a stay you've already accepted for this listing."
        case .notSignedIn:
            return "You're signed out. Sign back in to change this stay."
        }
    }
}

struct StayRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let listingID: String
    let listingCity: String
    let listingTitle: String?
    var listingHostName: String
    let hostUserID: String
    let guestUserID: String
    var checkIn: Date
    var checkOut: Date
    var guestNote: String?
    var hostNote: String?
    var guestCount: Int?
    var arrivalWindow: ArrivalWindow?
    var status: StayRequestStatus
    var initiatedBy: String?
    var completedAt: Date?
    var cancelledBy: String?
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    init(
        id: String = UUID().uuidString,
        listingID: String,
        listingCity: String,
        listingTitle: String? = nil,
        listingHostName: String,
        hostUserID: String,
        guestUserID: String,
        checkIn: Date,
        checkOut: Date,
        guestNote: String? = nil,
        hostNote: String? = nil,
        guestCount: Int? = nil,
        arrivalWindow: ArrivalWindow? = nil,
        status: StayRequestStatus = .pending,
        initiatedBy: String? = nil,
        completedAt: Date? = nil,
        cancelledBy: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.listingCity = listingCity
        self.listingTitle = listingTitle
        self.listingHostName = listingHostName
        self.hostUserID = hostUserID
        self.guestUserID = guestUserID
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.guestNote = guestNote
        self.hostNote = hostNote
        self.guestCount = guestCount
        self.arrivalWindow = arrivalWindow
        self.status = status
        self.initiatedBy = initiatedBy
        self.completedAt = completedAt
        self.cancelledBy = cancelledBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    var partySummary: String? {
        var parts: [String] = []
        if let guestCount { parts.append("\(guestCount) guest\(guestCount == 1 ? "" : "s")") }
        if let arrivalWindow { parts.append(arrivalWindow.shortName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func overlaps(checkIn otherCheckIn: Date, checkOut otherCheckOut: Date) -> Bool {
        checkIn < otherCheckOut && otherCheckIn < checkOut
    }

    static func == (lhs: StayRequest, rhs: StayRequest) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension StayRequest {
    /// How the requested home names itself in trip rows and the chat banner: the
    /// snapshotted title if there was one, otherwise the city. Mirrors
    /// `Home.displayTitle`'s intent for the denormalized copy.
    var listingLabel: String { namedListingTitle ?? listingCity }

    /// The snapshotted title only when the host actually set one (trimmed,
    /// non-empty), the denormalized twin of `Home.customTitle`. Surfaces that
    /// have their own fallback wording, like the chat banner's "your place",
    /// need to know the difference; `listingLabel` is for the ones that don't.
    var namedListingTitle: String? {
        guard let listingTitle else { return nil }
        let trimmed = listingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Mar 5 – Mar 9", the form used by every stay row and chat banner.
    var dateRangeText: String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: checkIn)) – \(f.string(from: checkOut))"
    }

    /// Which side of this stay `userID` is on, or nil if they're neither.
    func role(of userID: String) -> StayRequestRole? {
        if userID == hostUserID { return .host }
        if userID == guestUserID { return .guest }
        return nil
    }

    /// Which side started this: the guest asking, or the host offering. A request
    /// written before offers existed has no `initiatedBy`, and could only have
    /// been the guest asking, because that was the only thing the app could do.
    var initiator: StayRequestRole {
        initiatedBy == hostUserID ? .host : .guest
    }

    /// Whose answer the stay is waiting on, or nil if it isn't waiting on anyone.
    /// A guest's request waits on the host; a host's offer waits on the guest.
    var awaitingParty: String? {
        switch status {
        case .pending: return hostUserID
        case .offered: return guestUserID
        case .accepted, .completed, .declined, .cancelled: return nil
        }
    }

    /// Whether `userID` is the one who owes a reply. Backs the "Needs your
    /// response" section and the tab badge, which now count offers a guest hasn't
    /// answered alongside requests a host hasn't.
    func awaitsReply(from userID: String) -> Bool {
        !userID.isEmpty && awaitingParty == userID
    }

    /// Whether `userID` may accept this right now. Deliberately the mirror of
    /// `awaitsReply`, minus the statuses that aren't an open question: the person
    /// who owes the answer is exactly the person who can say yes.
    func canBeAccepted(by userID: String) -> Bool {
        status.isAwaitingReply && awaitsReply(from: userID)
    }

    /// The other participant, seen from `userID`.
    func otherParty(from userID: String) -> String {
        userID == hostUserID ? guestUserID : hostUserID
    }

    /// Either party may close out an accepted stay once it has begun. Requiring
    /// checkout to have passed would leave a guest who left early unable to say
    /// so, and the nightly sweep completes anything nobody touches, so the only
    /// thing this gate has to stop is marking a future stay complete.
    /// `firestore.rules` enforces the same `request.time >= checkIn` bound.
    func canBeMarkedComplete(now: Date = Date()) -> Bool {
        status == .accepted && now >= checkIn
    }

    /// True while an accepted stay is actually happening — from the start of the
    /// check-in day through the end of the checkout day — so the trip timeline can
    /// surface it as "happening now" (feature 21). `checkOut` is a local
    /// start-of-day, so the +1 day keeps the stay live for all of checkout day
    /// rather than flipping it to "past" at midnight while the guest is still there.
    func isUnderway(now: Date = Date()) -> Bool {
        guard status == .accepted, now >= checkIn else { return false }
        let dayAfterCheckout = Calendar.current.date(byAdding: .day, value: 1, to: checkOut) ?? checkOut
        return now < dayAfterCheckout
    }

    /// The review `userID` would write about the other party, if the stay is over.
    func reviewRole(for userID: String) -> ReviewRole? {
        guard status == .completed else { return nil }
        switch role(of: userID) {
        case .guest: return .guestReviewingHost
        case .host:  return .hostReviewingGuest
        case nil:    return nil
        }
    }
}

extension [StayRequest] {
    /// How many of these are waiting on `userID` to answer. Backs the Stays tab
    /// badge, which means "someone is blocked on you" and nothing looser. Pure,
    /// so the badge rule is testable without standing up a store and an auth
    /// session.
    func awaitingReplyCount(from userID: String) -> Int {
        // An empty userID is a signed-out viewer; `awaitsReply` already refuses
        // to match one, so this reduces to zero without a special case.
        filter { $0.awaitsReply(from: userID) }.count
    }

    /// Newest first. Requests without a server timestamp yet sort to the front
    /// so newly created pending items appear immediately.
    func sortedByDate() -> [StayRequest] {
        sorted {
            switch ($0.createdAt, $1.createdAt) {
            case (nil, nil):   return false
            case (nil, _):     return true   // pending write floats up
            case (_, nil):     return false
            case (let a, let b):
                guard let a, let b else { return false }
                return a > b
            }
        }
    }
}

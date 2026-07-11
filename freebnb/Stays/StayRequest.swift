//
//  StayRequest.swift
//  freebnb
//

import FirebaseFirestore
import Foundation

enum StayRequestStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case pending   = "pending"
    case accepted  = "accepted"
    /// The stay happened and is over. Reached either by a party tapping "Mark
    /// complete" once the stay has begun, or by the nightly `expireCompletedStays`
    /// sweep after checkout. This is the status that unlocks reviews and that
    /// `trustStats` counts (feature 4).
    case completed = "completed"
    case declined  = "declined"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .accepted:  return "Accepted"
        case .completed: return "Completed"
        case .declined:  return "Declined"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool { self == .pending || self == .accepted }

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

    var errorDescription: String? {
        switch self {
        case .overlappingStay:
            return "Those dates overlap a stay you've already accepted for this listing."
        }
    }
}

struct StayRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let listingID: String
    // Denormalized so the request row is displayable without fetching the listing.
    let listingCity: String
    // Denormalized copy of the host's display name, rewritten in place when the
    // host renames (L7); `var` so the in-memory repository can update it.
    var listingHostName: String
    let hostUserID: String
    let guestUserID: String
    var checkIn: Date
    var checkOut: Date
    var guestNote: String?
    var hostNote: String?
    // Number of guests and rough arrival time, captured on the request so the
    // host isn't left guessing (feature 20). Optional so requests created before
    // these fields decode cleanly; nil renders as "not specified".
    var guestCount: Int?
    var arrivalWindow: ArrivalWindow?
    var status: StayRequestStatus
    /// When the stay was marked complete. Nil for every other status; written
    /// alongside `status == .completed` and never rewritten.
    var completedAt: Date?
    @ServerTimestamp var createdAt: Date?
    @ServerTimestamp var updatedAt: Date?

    init(
        id: String = UUID().uuidString,
        listingID: String,
        listingCity: String,
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
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.listingCity = listingCity
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
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    /// Compact "2 guests · Morning arrival" line for request rows, or nil when
    /// neither field was captured (older requests).
    var partySummary: String? {
        var parts: [String] = []
        if let guestCount { parts.append("\(guestCount) guest\(guestCount == 1 ? "" : "s")") }
        if let arrivalWindow { parts.append(arrivalWindow.shortName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Half-open interval overlap: `[checkIn, checkOut)` against another window.
    /// The one definition of "these dates collide" shared by stay acceptance
    /// (the double-booking guard) and the request sheet's conflict warning.
    func overlaps(checkIn otherCheckIn: Date, checkOut otherCheckOut: Date) -> Bool {
        checkIn < otherCheckOut && otherCheckIn < checkOut
    }

    static func == (lhs: StayRequest, rhs: StayRequest) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension StayRequest {
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

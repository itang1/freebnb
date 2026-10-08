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

    /// Not yet resolved either way. An offer is active like a pending request,
    /// so `updateStatus` doesn't withdraw the address grant from under it.
    var isActive: Bool { self == .pending || self == .offered || self == .accepted }

    /// Whether this waits on somebody's answer; see `awaitingReply(from:)` for which side.
    var isAwaitingReply: Bool { self == .pending || self == .offered }

    /// Statuses meaning the stay happened; `accepted` counts since an in-progress stay isn't cancelled.
    var didHappen: Bool { self == .accepted || self == .completed }
}

enum StayRequestRole: Sendable {
    case guest
    case host
}

/// Roughly when the guest expects to arrive. Stored by raw value; the rules validate membership.
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
    /// The request moved on between rendering and the tap: cancelled, or answered on another device.
    case noLongerPending
    case listingUnavailable

    var errorDescription: String? {
        switch self {
        case .overlappingStay:
            return "Those dates overlap a stay you've already accepted for this listing."
        case .notSignedIn:
            return "You're signed out. Sign back in to change this stay."
        case .noLongerPending:
            return "This request has already been answered."
        case .listingUnavailable:
            return "This listing is no longer available."
        }
    }

    /// What a guest sees when a write fails. A rules rejection (permission-denied)
    /// becomes the same "no longer available" as a taken night, since both mean the
    /// listing's calendar or rules moved under the open sheet. Other errors keep their description.
    static func guestFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        let isDenied = nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
        return isDenied
            ? (StayRequestError.listingUnavailable.errorDescription ?? "This listing is no longer available.")
            : error.localizedDescription
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
    /// How the home names itself in trip rows and the chat banner: the snapshotted title, else the city.
    var listingLabel: String { namedListingTitle ?? listingCity }

    /// The snapshotted title only if the host set one; the twin of `Home.customTitle`,
    /// for surfaces with their own fallback wording. `listingLabel` is for the rest.
    var namedListingTitle: String? {
        guard let listingTitle else { return nil }
        let trimmed = listingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Mar 5 – Mar 9", as used by every stay row and chat banner.
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

    /// Which side started this: guest asking or host offering. Requests without
    /// `initiatedBy` predate offers and were the guest's.
    var initiator: StayRequestRole {
        initiatedBy == hostUserID ? .host : .guest
    }

    /// Whose answer the stay waits on (host for a request, guest for an offer), or nil.
    var awaitingParty: String? {
        switch status {
        case .pending: return hostUserID
        case .offered: return guestUserID
        case .accepted, .completed, .declined, .cancelled: return nil
        }
    }

    /// Whether `userID` owes a reply; backs the "Needs your response" section and tab badge.
    func awaitsReply(from userID: String) -> Bool {
        !userID.isEmpty && awaitingParty == userID
    }

    /// Whether `userID` may accept right now: the mirror of `awaitsReply`.
    func canBeAccepted(by userID: String) -> Bool {
        status.isAwaitingReply && awaitsReply(from: userID)
    }

    /// The other participant, seen from `userID`.
    func otherParty(from userID: String) -> String {
        userID == hostUserID ? guestUserID : hostUserID
    }

    /// Either party may close out an accepted stay once it has begun. Requiring
    /// checkout would block a guest who left early; the sweep completes the rest,
    /// so the gate only stops completing a future stay. Rules enforce `request.time >= checkIn`.
    func canBeMarkedComplete(now: Date = Date()) -> Bool {
        status == .accepted && now >= checkIn
    }

    /// True while an accepted stay is happening, from the start of check-in day
    /// through the end of checkout day (`checkOut` is a start-of-day, hence +1 day).
    func isUnderway(now: Date = Date()) -> Bool {
        guard status == .accepted, now >= checkIn else { return false }
        let dayAfterCheckout = Calendar.current.date(byAdding: .day, value: 1, to: checkOut) ?? checkOut
        return now < dayAfterCheckout
    }

    /// True while an accepted stay still has a future: from acceptance through the
    /// end of checkout day. Bounded at checkout rather than `status`, since the
    /// nightly sweep can be late or never run where no functions are deployed.
    func isOutstanding(now: Date = Date()) -> Bool {
        guard status == .accepted else { return false }
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
    /// The outstanding accepted stay between these two people, if any. Backs the
    /// unfriend guard: unfriending mid-stay would remove the thread they need
    /// for keys and late arrivals. Blocking is deliberately not gated, as a safety exit.
    func outstandingStay(between viewerID: String, and otherID: String, now: Date = Date()) -> StayRequest? {
        first { stay in
            stay.isOutstanding(now: now)
                && ((stay.hostUserID == viewerID && stay.guestUserID == otherID)
                    || (stay.hostUserID == otherID && stay.guestUserID == viewerID))
        }
    }

    /// How many are waiting on `userID` to answer; backs the Stays tab badge. Pure, so testable without a store.
    func awaitingReplyCount(from userID: String) -> Int {
        // An empty userID is signed out; `awaitsReply` refuses to match it, so this is zero.
        filter { $0.awaitsReply(from: userID) }.count
    }

    /// Newest first; requests without a server timestamp sort to the front.
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

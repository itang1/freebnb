//
//  StayRequest.swift
//  freebnb
//

import FirebaseFirestore
import Foundation

enum StayRequestStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case pending   = "pending"
    case accepted  = "accepted"
    case declined  = "declined"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .accepted:  return "Accepted"
        case .declined:  return "Declined"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool { self == .pending || self == .accepted }
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

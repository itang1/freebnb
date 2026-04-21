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

struct StayRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let listingID: String
    // Denormalized so the request row is displayable without fetching the listing.
    let listingCity: String
    let listingHostName: String
    let hostUserID: String
    let guestUserID: String
    var checkIn: Date
    var checkOut: Date
    var guestNote: String?
    var hostNote: String?
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
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    static func == (lhs: StayRequest, rhs: StayRequest) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

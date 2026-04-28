//
//  Home.swift
//  freebnb
//

import Foundation

struct Address: Codable, Hashable {
    var street: String
    var city: String
    var state: String
    var zip: String
}

enum FoodProvision: String, CaseIterable, Hashable, Codable {
    case all         = "all"
    case some        = "some"
    case bareMinimum = "bareMinimum"
    case none        = "none"

    var displayName: String {
        switch self {
        case .all:         return "All meals provided"
        case .some:        return "Some food provided"
        case .bareMinimum: return "Bare minimum provided"
        case .none:        return "No food provided"
        }
    }
}

enum SleepingSurface: String, CaseIterable, Hashable, Codable {
    case bed         = "bed"
    case airMattress = "airMattress"
    case couch       = "couch"
    case futon       = "futon"
    case floorMat    = "floorMat"

    var displayName: String {
        switch self {
        case .bed:         return "bed"
        case .airMattress: return "air mattress"
        case .couch:       return "couch"
        case .futon:       return "futon"
        case .floorMat:    return "floor mat"
        }
    }
}

enum HostContactPreference: String, Hashable, Codable {
    case inApp       = "inApp"
    case contactInfo = "contactInfo"
}

enum CancellationPolicy: String, CaseIterable, Hashable, Codable {
    case flexible = "flexible"
    case moderate = "moderate"
    case strict   = "strict"

    var displayName: String {
        switch self {
        case .flexible: return "Flexible"
        case .moderate: return "Moderate"
        case .strict:   return "Strict"
        }
    }

    var description: String {
        switch self {
        case .flexible: return "Cancel any time before the stay with no issue."
        case .moderate: return "Cancel at least 48 hours before check-in."
        case .strict:   return "No cancellations once the stay is confirmed."
        }
    }

    /// Sort key for "Most Flexible Cancellation" — higher means more flexible.
    var flexibilityRank: Int {
        switch self {
        case .flexible: return 2
        case .moderate: return 1
        case .strict:   return 0
        }
    }
}

enum HostMotivation: String, CaseIterable, Hashable, Codable {
    case eager      = "eager"
    case open       = "open"
    case selective  = "selective"

    var displayName: String {
        switch self {
        case .eager:     return "I'd love to host"
        case .open:      return "I'm open to hosting"
        case .selective: return "I have limited availability"
        }
    }

    var description: String {
        switch self {
        case .eager:
            return "This host is actively looking to welcome guests and make connections."
        case .open:
            return "This host is happy to have guests, though it isn't a top priority."
        case .selective:
            return "This host is particular about guests and has limited availability."
        }
    }

    var iconName: String {
        switch self {
        case .eager:     return "heart.fill"
        case .open:      return "heart"
        case .selective: return "heart.slash"
        }
    }

    /// Sort key for "Most Eager to Host" — higher means more eager.
    var rank: Int {
        switch self {
        case .eager:     return 2
        case .open:      return 1
        case .selective: return 0
        }
    }
}

// MARK: - Nested types

struct Sleeping: Codable, Hashable {
    var numGuestRooms: Int
    // Firestore-compatible [String: Int] map; use sleepingCounts for a typed view.
    var arrangements: [String: Int]

    var sleepingCounts: [SleepingSurface: Int] {
        var result: [SleepingSurface: Int] = [:]
        for (raw, count) in arrangements {
            if let surface = SleepingSurface(rawValue: raw), count > 0 {
                result[surface] = count
            }
        }
        return result
    }

    var arrangementsDescription: String {
        sleepingCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.displayName)" }
            .joined(separator: ", ")
    }
}

struct GuestPolicy: Codable, Hashable {
    var maxGuests: Int
    var maxStayDays: Int
    var kidsAllowed: Bool
    var guestPetsAllowed: Bool
}

struct Amenities: Codable, Hashable {
    // Comfort
    var hasAC: Bool
    var hasHeating: Bool
    var hasKitchen: Bool
    var hasFridgeSpace: Bool
    var hasMicrowave: Bool
    var hasTV: Bool
    var hasWifi: Bool
    // Rooms & laundry
    var hasPrivateGuestBathroom: Bool
    var hostHasPets: Bool
    var parkingDetails: String
    var hasInUnitLaundry: Bool
    var hasCoinLaundryNearby: Bool
    // Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    var foodProvision: FoodProvision

    var count: Int {
        [hasAC, hasHeating, hasKitchen, hasFridgeSpace, hasMicrowave, hasTV, hasWifi,
         hasPrivateGuestBathroom, hostHasPets, hasInUnitLaundry, hasCoinLaundryNearby,
         providesPillows, providesBlankets, providesTowels, providesToiletries]
            .filter { $0 }.count
    }
}

// MARK: - Home

struct Home: Identifiable, Hashable, Codable {
    // `var` rather than `let` so the edit path can construct a Home with an
    // existing listing's id (the memberwise init doesn't expose `let`
    // properties that have default values). Treat as immutable after
    // creation; identity-based equality in this file depends on it.
    var id: String = UUID().uuidString

    // MARK: Host and location
    var hostUserID: String
    var hostName: String
    var address: Address
    var description: String?
    var contactPreference: HostContactPreference
    var hostContactInfo: String?
    var hostMotivation: HostMotivation

    // MARK: Capacity, guest policy, and amenities
    var sleeping: Sleeping
    var guestPolicy: GuestPolicy
    var amenities: Amenities

    // MARK: Cancellation policy
    // Optional so listings created before this field was added decode cleanly.
    // Nil is treated as .flexible in the UI.
    var cancellationPolicy: CancellationPolicy? = nil

    // MARK: Photos
    // Optional on the wire so documents created before photo support decode
    // cleanly. Access through `photos` for a non-optional view.
    var photoURLs: [String]? = nil

    // MARK: Soft delete
    // Nil means active. Set by the repository to the server timestamp on delete;
    // the HomeStore filters out non-nil entries so deleted listings never appear
    // in the feed while the Firestore document is preserved for history.
    var deletedAt: Date? = nil

    // Identity-based equality and hashing, kept consistent per Hashable contract.
    static func == (lhs: Home, rhs: Home) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Non-optional view of photo URLs for view code.
    var photos: [String] { photoURLs ?? [] }

    enum CodingKeys: String, CodingKey {
        case id, hostUserID, hostName, address, description
        case contactPreference, hostContactInfo, hostMotivation
        case sleeping, guestPolicy, amenities
        case cancellationPolicy
        case photoURLs
        case deletedAt
    }
}

// MARK: - Custom Decodable

// In an extension so the memberwise initializer is preserved. Fields added
// after the initial schema use decodeIfPresent so existing Firestore documents
// without those keys decode successfully instead of being silently dropped.
extension Home {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decodeIfPresent(String.self,               forKey: .id)                ?? UUID().uuidString
        hostUserID         = try c.decode(String.self,                         forKey: .hostUserID)
        hostName           = try c.decode(String.self,                         forKey: .hostName)
        address            = try c.decode(Address.self,                        forKey: .address)
        description        = try c.decodeIfPresent(String.self,               forKey: .description)
        contactPreference  = try c.decodeIfPresent(HostContactPreference.self, forKey: .contactPreference) ?? .inApp
        hostContactInfo    = try c.decodeIfPresent(String.self,               forKey: .hostContactInfo)
        hostMotivation     = try c.decodeIfPresent(HostMotivation.self,       forKey: .hostMotivation)    ?? .open
        sleeping           = try c.decode(Sleeping.self,                       forKey: .sleeping)
        guestPolicy        = try c.decode(GuestPolicy.self,                    forKey: .guestPolicy)
        amenities          = try c.decode(Amenities.self,                      forKey: .amenities)
        cancellationPolicy = try c.decodeIfPresent(CancellationPolicy.self,   forKey: .cancellationPolicy)
        photoURLs          = try c.decodeIfPresent([String].self,              forKey: .photoURLs)
        deletedAt          = try c.decodeIfPresent(Date.self,                 forKey: .deletedAt)
    }
}

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

    /// Sort key for "Most Eager" — higher means more eager.
    var rank: Int {
        switch self {
        case .eager:     return 2
        case .open:      return 1
        case .selective: return 0
        }
    }
}

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

    // MARK: Capacity
    var numGuestRooms: Int
    var maxGuests: Int
    var maxStayDays: Int
    // Firestore-compatible storage; access through `sleepingCounts` for a typed view.
    var sleepingArrangements: [String: Int]
    var kidsAllowed: Bool
    var guestPetsAllowed: Bool
    var hostHasPets: Bool

    // MARK: Comfort and amenities
    var hasAC: Bool
    var hasHeating: Bool
    var hasKitchen: Bool
    var hasFridgeSpace: Bool
    var hasMicrowave: Bool
    var hasTV: Bool
    var hasWifi: Bool

    // MARK: Other rooms
    var hasPrivateGuestBathroom: Bool
    var parkingDetails: String
    var hasInUnitLaundry: Bool
    var hasCoinLaundryNearby: Bool

    // MARK: Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    var foodProvision: FoodProvision

    // MARK: Photos
    // Optional on the wire so documents created before photo support decode
    // cleanly. Access through `photos` for a non-optional view.
    var photoURLs: [String]? = nil

    // Identity-based equality and hashing, kept consistent per Hashable contract.
    static func == (lhs: Home, rhs: Home) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Typed view of `sleepingArrangements`; unknown raw keys are dropped.
    var sleepingCounts: [SleepingSurface: Int] {
        var result: [SleepingSurface: Int] = [:]
        for (raw, count) in sleepingArrangements {
            if let surface = SleepingSurface(rawValue: raw), count > 0 {
                result[surface] = count
            }
        }
        return result
    }

    // Non-optional view of photo URLs for view code.
    var photos: [String] { photoURLs ?? [] }

    var sleepingArrangementsDescription: String {
        sleepingCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.displayName)" }
            .joined(separator: ", ")
    }

    // CodingKeys must live in the struct body (not an extension) so that Swift
    // can use them to synthesize encode(to:). The matching init(from:) lives in
    // the extension below so that the memberwise initializer is preserved for
    // call sites that construct Home values directly.
    enum CodingKeys: String, CodingKey {
        case id, hostUserID, hostName, address, description
        case contactPreference, hostContactInfo, hostMotivation
        case numGuestRooms, maxGuests, maxStayDays, sleepingArrangements
        case kidsAllowed, guestPetsAllowed, hostHasPets
        case hasAC, hasHeating, hasKitchen, hasFridgeSpace, hasMicrowave, hasTV, hasWifi
        case hasPrivateGuestBathroom, parkingDetails, hasInUnitLaundry, hasCoinLaundryNearby
        case providesPillows, providesBlankets, providesTowels, providesToiletries, foodProvision
        case photoURLs
    }

}

// MARK: - Custom Decodable

// In an extension so the memberwise initializer is preserved. Fields added
// after the initial schema use decodeIfPresent so existing Firestore documents
// without those keys decode successfully instead of being silently dropped.
extension Home {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                      = try c.decodeIfPresent(String.self,                  forKey: .id)                    ?? UUID().uuidString
        hostUserID              = try c.decode(String.self,                            forKey: .hostUserID)
        hostName                = try c.decode(String.self,                            forKey: .hostName)
        address                 = try c.decode(Address.self,                           forKey: .address)
        description             = try c.decodeIfPresent(String.self,                  forKey: .description)
        contactPreference       = try c.decodeIfPresent(HostContactPreference.self,   forKey: .contactPreference)     ?? .inApp
        hostContactInfo         = try c.decodeIfPresent(String.self,                  forKey: .hostContactInfo)
        hostMotivation          = try c.decodeIfPresent(HostMotivation.self,          forKey: .hostMotivation)        ?? .open
        numGuestRooms           = try c.decode(Int.self,                              forKey: .numGuestRooms)
        maxGuests               = try c.decode(Int.self,                              forKey: .maxGuests)
        maxStayDays             = try c.decode(Int.self,                              forKey: .maxStayDays)
        sleepingArrangements    = try c.decodeIfPresent([String: Int].self,           forKey: .sleepingArrangements)  ?? [:]
        kidsAllowed             = try c.decode(Bool.self,                             forKey: .kidsAllowed)
        guestPetsAllowed        = try c.decode(Bool.self,                             forKey: .guestPetsAllowed)
        hostHasPets             = try c.decode(Bool.self,                             forKey: .hostHasPets)
        hasAC                   = try c.decode(Bool.self,                             forKey: .hasAC)
        hasHeating              = try c.decode(Bool.self,                             forKey: .hasHeating)
        hasKitchen              = try c.decode(Bool.self,                             forKey: .hasKitchen)
        hasFridgeSpace          = try c.decode(Bool.self,                             forKey: .hasFridgeSpace)
        hasMicrowave            = try c.decode(Bool.self,                             forKey: .hasMicrowave)
        hasTV                   = try c.decode(Bool.self,                             forKey: .hasTV)
        hasWifi                 = try c.decode(Bool.self,                             forKey: .hasWifi)
        hasPrivateGuestBathroom = try c.decode(Bool.self,                             forKey: .hasPrivateGuestBathroom)
        parkingDetails          = try c.decodeIfPresent(String.self,                  forKey: .parkingDetails)        ?? ""
        hasInUnitLaundry        = try c.decode(Bool.self,                             forKey: .hasInUnitLaundry)
        hasCoinLaundryNearby    = try c.decode(Bool.self,                             forKey: .hasCoinLaundryNearby)
        providesPillows         = try c.decode(Bool.self,                             forKey: .providesPillows)
        providesBlankets        = try c.decode(Bool.self,                             forKey: .providesBlankets)
        providesTowels          = try c.decode(Bool.self,                             forKey: .providesTowels)
        providesToiletries      = try c.decode(Bool.self,                             forKey: .providesToiletries)
        foodProvision           = try c.decodeIfPresent(FoodProvision.self,           forKey: .foodProvision)         ?? .none
        photoURLs               = try c.decodeIfPresent([String].self,                forKey: .photoURLs)
    }
}

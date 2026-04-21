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

struct Home: Identifiable, Hashable, Codable {
    let id: String = UUID().uuidString

    // MARK: Host and location
    var hostUserID: String
    var hostName: String
    var address: Address
    var description: String?
    var contactPreference: HostContactPreference
    var hostContactInfo: String?

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

    var sleepingArrangementsDescription: String {
        sleepingCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.displayName)" }
            .joined(separator: ", ")
    }
}

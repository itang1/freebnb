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
    case all = "All meals provided"
    case some = "Some food provided"
    case bareMinimum = "Bare minimum provided"
    case none = "No food provided"
}

enum SleepingSurface: String, Hashable {
    case bed
    case airMattress
    case couch
    case futon
    case floorMat
}

enum HostContactPreference {
    case inApp
    case contactInfo
}

struct Home: Identifiable, Hashable {
    let id = UUID()

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
    var sleepingArrangements: [SleepingSurface: Int]
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
}

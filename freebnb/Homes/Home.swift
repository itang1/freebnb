//
//  Home.swift
//  freebnb
//

import Foundation

/// The world-readable part of a listing's location. The street lives in
/// `ListingLocation`, not here, because every signed-in user can read a public
/// listing document and an anonymous account is one tap away.
///
/// Documents written before the split still carry a `street` key; the synthesized
/// decoder ignores it, and the next host save drops it. Such legacy documents were
/// cleared by the reset-and-reseed (scripts/seed_test_data.js --reset), so the
/// decoder's tolerance is now just defensive.
struct Address: Codable, Hashable {
    var city: String
    var state: String
    var zip: String
}

/// The part of a listing's location that is disclosed progressively: the host
/// always sees it, and a guest only once the host has accepted their stay.
/// Stored at `homes/{id}/private/location`, gated by `firestore.rules` on the
/// existence of `homes/{id}/accepted/{guestUserID}`.
struct ListingLocation: Codable, Hashable, Sendable {
    var street: String
    /// Exact coordinates. `Home.latitude`/`longitude` are the rounded public copy.
    var latitude: Double?
    var longitude: Double?
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

/// The size of a `SleepingSurface.bed` (feature 17). Separate from the surface
/// because a couch has no size worth naming and an air mattress's is nobody's
/// deciding factor, whereas "is the bed big enough for two of us" routinely is.
enum BedSize: String, CaseIterable, Hashable, Codable {
    case twin  = "twin"
    case full  = "full"
    case queen = "queen"
    case king  = "king"

    var displayName: String {
        switch self {
        case .twin:  return "twin"
        case .full:  return "full"
        case .queen: return "queen"
        case .king:  return "king"
        }
    }

    /// Sleeps two adults comfortably. Backs the "Queen or king bed" filter.
    var sleepsTwo: Bool { self == .queen || self == .king }

    /// Menu and summary order: smallest first.
    var rank: Int {
        switch self {
        case .twin:  return 0
        case .full:  return 1
        case .queen: return 2
        case .king:  return 3
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

/// Who can see a listing, ordered most private to most open — which is also the
/// order the picker offers them in (feature 7).
///
/// Both restricted tiers are enforced through the same denormalized
/// `allowedViewerIDs` array, because Firestore rules cannot join to `friendEdges`
/// at query time. What differs is who the server puts in that array: the host's
/// friends for `friendsOnly`, and those friends' friends as well for
/// `friendsOfFriends`. The `rebuildListingACLs` Cloud Function owns it.
enum ListingVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case friendsOnly      = "friendsOnly"
    case friendsOfFriends = "friendsOfFriends"
    case everyone         = "everyone"

    var displayName: String {
        switch self {
        case .friendsOnly:      return "Friends only"
        case .friendsOfFriends: return "Friends of friends"
        case .everyone:         return "Everyone"
        }
    }

    var description: String {
        switch self {
        case .friendsOnly:
            return "Only people you are connected with can see this listing."
        case .friendsOfFriends:
            return "Your friends, and anyone they are connected with, can see this listing."
        case .everyone:
            return "Anyone on FreeBNB can see this listing."
        }
    }

    /// True when the listing is gated by `allowedViewerIDs` rather than open to
    /// every signed-in user.
    var isRestricted: Bool { self != .everyone }
}

struct DateRange: Codable, Hashable, Identifiable, Sendable {
    var start: Date
    var end: Date
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }

    func overlaps(checkIn: Date, checkOut: Date) -> Bool {
        checkIn < end && checkOut > start
    }
}

// MARK: - Nested types

struct Sleeping: Codable, Hashable {
    var numGuestRooms: Int
    // Firestore-compatible [String: Int] map; use sleepingCounts for a typed view.
    var arrangements: [String: Int]

    // MARK: Richer capacity (feature 17)
    // Bathrooms a guest may use, shared or private. Zero means the host never
    // said — the UI hides the pill rather than guessing at one, since claiming a
    // bathroom that may not exist is worse than saying nothing.
    var numBathrooms: Int = 0
    // Sizes of the beds counted in `arrangements["bed"]`, keyed by
    // `BedSize.rawValue`; use `bedSizeCounts` for a typed view. Empty when the
    // host didn't say, which is also the only thing a legacy document can mean.
    var bedSizes: [String: Int] = [:]

    var sleepingCounts: [SleepingSurface: Int] {
        var result: [SleepingSurface: Int] = [:]
        for (raw, count) in arrangements {
            if let surface = SleepingSurface(rawValue: raw), count > 0 {
                result[surface] = count
            }
        }
        return result
    }

    /// Typed view of `bedSizes`, dropping raw values that no longer name a size.
    var bedSizeCounts: [BedSize: Int] {
        var result: [BedSize: Int] = [:]
        for (raw, count) in bedSizes {
            if let size = BedSize(rawValue: raw), count > 0 {
                result[size] = count
            }
        }
        return result
    }

    /// Whether any bed sleeps two adults. Backs the "Queen or king bed" filter.
    var hasBedForTwo: Bool { bedSizeCounts.keys.contains(where: \.sleepsTwo) }

    var arrangementsDescription: String {
        sleepingCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.displayName)" }
            .joined(separator: ", ")
    }

    /// "1 queen, 2 twins", smallest first. Empty when no sizes were recorded.
    var bedSizesDescription: String {
        bedSizeCounts
            .sorted { $0.key.rank < $1.key.rank }
            .map { "\($0.value) \($0.key.displayName)\($0.value == 1 ? "" : "s")" }
            .joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case numGuestRooms, arrangements, numBathrooms, bedSizes
    }
}

// Fields added after the initial schema decode with `decodeIfPresent`, so a
// listing written before they existed still decodes instead of vanishing from
// the feed — a decode failure is dropped silently (A5). In an extension so the
// memberwise initializer survives; its new parameters carry defaults, so existing
// call sites are unaffected.
extension Sleeping {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        numGuestRooms = try c.decode(Int.self, forKey: .numGuestRooms)
        arrangements  = try c.decode([String: Int].self, forKey: .arrangements)
        numBathrooms  = try c.decodeIfPresent(Int.self, forKey: .numBathrooms) ?? 0
        bedSizes      = try c.decodeIfPresent([String: Int].self, forKey: .bedSizes) ?? [:]
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

    // MARK: Accessibility (feature 17)
    // Declared last, and defaulted, so the memberwise initializer keeps working
    // for every call site written before they existed. False means "the host did
    // not say it is accessible", never "the host said it isn't" — which is why
    // these are filters a guest opts into, and why nothing renders a red X for an
    // absent one.
    var hasStepFreeEntry: Bool = false
    var hasElevator: Bool = false
    var hasAccessibleBathroom: Bool = false

    /// Whether the host claimed any accessibility attribute at all.
    var hasAnyAccessibility: Bool { hasStepFreeEntry || hasElevator || hasAccessibleBathroom }

    /// Backs the "Most Amenities" sort. Accessibility is deliberately excluded:
    /// step-free entry is a fact about a home, not a perk it competes on, and
    /// ranking homes by it would push accessible listings up the feed for guests
    /// who never asked.
    var count: Int {
        [hasAC, hasHeating, hasKitchen, hasFridgeSpace, hasMicrowave, hasTV, hasWifi,
         hasPrivateGuestBathroom, hostHasPets, hasInUnitLaundry, hasCoinLaundryNearby,
         providesPillows, providesBlankets, providesTowels, providesToiletries]
            .filter { $0 }.count
    }

    enum CodingKeys: String, CodingKey {
        case hasAC, hasHeating, hasKitchen, hasFridgeSpace, hasMicrowave, hasTV, hasWifi
        case hasPrivateGuestBathroom, hostHasPets, parkingDetails
        case hasInUnitLaundry, hasCoinLaundryNearby
        case providesPillows, providesBlankets, providesTowels, providesToiletries
        case foodProvision
        case hasStepFreeEntry, hasElevator, hasAccessibleBathroom
    }
}

// Same reasoning as `Sleeping` above: the accessibility keys post-date the schema,
// so a listing saved without them must still decode.
extension Amenities {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasAC                   = try c.decode(Bool.self, forKey: .hasAC)
        hasHeating              = try c.decode(Bool.self, forKey: .hasHeating)
        hasKitchen              = try c.decode(Bool.self, forKey: .hasKitchen)
        hasFridgeSpace          = try c.decode(Bool.self, forKey: .hasFridgeSpace)
        hasMicrowave            = try c.decode(Bool.self, forKey: .hasMicrowave)
        hasTV                   = try c.decode(Bool.self, forKey: .hasTV)
        hasWifi                 = try c.decode(Bool.self, forKey: .hasWifi)
        hasPrivateGuestBathroom = try c.decode(Bool.self, forKey: .hasPrivateGuestBathroom)
        hostHasPets             = try c.decode(Bool.self, forKey: .hostHasPets)
        parkingDetails          = try c.decode(String.self, forKey: .parkingDetails)
        hasInUnitLaundry        = try c.decode(Bool.self, forKey: .hasInUnitLaundry)
        hasCoinLaundryNearby    = try c.decode(Bool.self, forKey: .hasCoinLaundryNearby)
        providesPillows         = try c.decode(Bool.self, forKey: .providesPillows)
        providesBlankets        = try c.decode(Bool.self, forKey: .providesBlankets)
        providesTowels          = try c.decode(Bool.self, forKey: .providesTowels)
        providesToiletries      = try c.decode(Bool.self, forKey: .providesToiletries)
        foodProvision           = try c.decode(FoodProvision.self, forKey: .foodProvision)
        hasStepFreeEntry        = try c.decodeIfPresent(Bool.self, forKey: .hasStepFreeEntry) ?? false
        hasElevator             = try c.decodeIfPresent(Bool.self, forKey: .hasElevator) ?? false
        hasAccessibleBathroom   = try c.decodeIfPresent(Bool.self, forKey: .hasAccessibleBathroom) ?? false
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

    // MARK: Availability
    // Nil or empty means fully available. Host marks date ranges as blocked;
    // guests cannot request stays that overlap any blocked range.
    var blockedDateRanges: [DateRange]? = nil

    // MARK: Location coordinates
    // Geocoded at save time and then deliberately blurred: this document is
    // world-readable, so the public coordinate is rounded to a neighbourhood
    // (see `approximate(_:)`). Exact coordinates live in the private location
    // subdocument. Nil for listings created before this field was added.
    var latitude: Double? = nil
    var longitude: Double? = nil

    // MARK: Geohash
    // A geohash of the public (blurred) coordinate, kept as an indexable key for
    // proximity range queries (feature 11). Stamped by the client on save
    // whenever coordinates resolve; nil for listings saved before this field or
    // whose address wouldn't geocode.
    var geohash: String? = nil

    // MARK: Visibility
    // Optional on the wire so listings created before this field decode cleanly.
    // Nil is treated as .everyone.
    var visibility: ListingVisibility? = nil

    // Denormalized read ACL: the host plus every accepted friend of the host.
    // Firestore rules cannot join to `friendEdges` at query time, so friends-only
    // visibility is enforced by reading this array directly (see firestore.rules)
    // and by querying `allowedViewerIDs contains me`. Written by the client on
    // every listing save and kept in sync by the `onFriendEdgeWritten` function.
    // Nil only on legacy documents (since cleared by reset-and-reseed); treat as
    // "host only".
    var allowedViewerIDs: [String]? = nil

    // MARK: Co-hosts
    // Friends the host has deputized to keep this listing accurate (feature 14):
    // a partner, a roommate. They may edit the listing's description of the home
    // and read and write its private location and house manual. They may not
    // change who hosts it, who can see it, who else co-hosts it, or delete it —
    // and stay requests still go to the host alone. `firestore.rules` is where
    // that boundary actually lives; this array is only its input.
    var coHostUserIDs: [String]? = nil

    // MARK: Soft delete
    // Nil means active. Set by the repository to the server timestamp on delete;
    // the HomeStore filters out non-nil entries so deleted listings never appear
    // in the feed while the Firestore document is preserved for history.
    var deletedAt: Date? = nil

    // MARK: Creation time
    // The feed's recency ordering key. Stamped with the server timestamp by the
    // repository on create and preserved across edits. A document without it is
    // excluded from the order-by query; legacy listings that lacked it were
    // cleared by the reset-and-reseed, and the seed stamps every listing, so this
    // is nil only in defensive theory now.
    var createdAt: Date? = nil

    // Identity-based equality and hashing, kept consistent per Hashable contract.
    static func == (lhs: Home, rhs: Home) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Non-optional view of photo URLs for view code.
    var photos: [String] { photoURLs ?? [] }

    /// Non-optional view of the co-host roster.
    var coHosts: [String] { coHostUserIDs ?? [] }

    /// The most a co-host roster may hold. Mirrored by `isOptionalList(data,
    /// 'coHostUserIDs', 5)` in `firestore.rules`, which is what enforces it.
    static let maxCoHosts = 5

    /// Whether `userID` may edit this listing's description of the home, and read
    /// its street address and house manual. The host, or one of their co-hosts.
    func isManagedBy(_ userID: String) -> Bool {
        guard !userID.isEmpty else { return false }
        return hostUserID == userID || coHosts.contains(userID)
    }

    /// Whether `userID` owns the listing. Distinct from `isManagedBy`: only the
    /// host may delete the listing, change its visibility, manage the co-host
    /// roster, or accept a guest into the home.
    func isHostedBy(_ userID: String) -> Bool {
        !userID.isEmpty && hostUserID == userID
    }

    /// The read ACL a listing starts with: the host, then their accepted friends,
    /// de-duplicated. Kept here so the client write path and the seed script agree
    /// on one definition. A `friendsOfFriends` listing needs a wider ACL than the
    /// client can compute (it can only read its own friend edges), so
    /// `rebuildListingACLs` widens it server-side right after the save.
    static func viewerIDs(hostUserID: String, friendIDs: some Sequence<String>) -> [String] {
        var seen: Set<String> = []
        return ([hostUserID] + friendIDs).filter { seen.insert($0).inserted }
    }

    /// Decimal places kept on the public coordinate. Two places is on the order of
    /// a kilometre, which places a listing in a neighbourhood without pointing at
    /// a front door. `scripts/seed_test_data.js` applies the same rounding.
    static let publicCoordinatePrecision = 2.0

    /// Blurs an exact coordinate component for the world-readable document.
    static func approximate(_ value: Double) -> Double {
        let scale = pow(10.0, publicCoordinatePrecision)
        return (value * scale).rounded() / scale
    }

    enum CodingKeys: String, CodingKey {
        case id, hostUserID, hostName, address, description
        case contactPreference, hostContactInfo, hostMotivation
        case sleeping, guestPolicy, amenities
        case cancellationPolicy
        case photoURLs
        case blockedDateRanges
        case latitude, longitude
        case geohash
        case visibility
        case allowedViewerIDs
        case coHostUserIDs
        case deletedAt
        case createdAt
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
        cancellationPolicy  = try c.decodeIfPresent(CancellationPolicy.self,  forKey: .cancellationPolicy)
        photoURLs           = try c.decodeIfPresent([String].self,            forKey: .photoURLs)
        blockedDateRanges   = try c.decodeIfPresent([DateRange].self,         forKey: .blockedDateRanges)
        latitude            = try c.decodeIfPresent(Double.self,              forKey: .latitude)
        longitude          = try c.decodeIfPresent(Double.self,               forKey: .longitude)
        geohash            = try c.decodeIfPresent(String.self,               forKey: .geohash)
        visibility         = try c.decodeIfPresent(ListingVisibility.self,    forKey: .visibility)
        allowedViewerIDs   = try c.decodeIfPresent([String].self,             forKey: .allowedViewerIDs)
        coHostUserIDs      = try c.decodeIfPresent([String].self,             forKey: .coHostUserIDs)
        deletedAt          = try c.decodeIfPresent(Date.self,                 forKey: .deletedAt)
        createdAt          = try c.decodeIfPresent(Date.self,                 forKey: .createdAt)
    }
}

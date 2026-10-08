//
//  Home.swift
//  freebnb
//

import Foundation

/// The world-readable part of a listing's location. The street lives in
/// `ListingLocation`, since every signed-in user (anonymous included) can read
/// a public listing. Legacy `street` keys are ignored by the decoder.
struct Address: Codable, Hashable {
    var city: String
    var state: String
    var zip: String
}

/// The progressively disclosed part of a listing's location: always visible to
/// the host, visible to a guest only once the stay is accepted. Stored at
/// `homes/{id}/private/location`.
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

    /// Spelled out because two of these take -es and a bare -s gave "couchs".
    var pluralName: String {
        switch self {
        case .bed:         return "beds"
        case .airMattress: return "air mattresses"
        case .couch:       return "couches"
        case .futon:       return "futons"
        case .floorMat:    return "floor mats"
        }
    }

    /// The plural-aware form for a count.
    func name(count: Int) -> String { count == 1 ? displayName : pluralName }
}

/// The size of a `SleepingSurface.bed`. Only beds get one; nobody decides on a couch's size.
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

    /// Sort key for "Most Flexible Cancellation"; higher is more flexible.
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

    /// Phrased per listing, since motivation can differ across a host's homes.
    var homeText: String {
        switch self {
        case .eager:     return "I'd love to host at this home"
        case .open:      return "I'm open to hosting at this home"
        case .selective: return "I have limited availability at this home"
        }
    }

    /// Sort key for "Most Eager to Host"; higher is more eager.
    var rank: Int {
        switch self {
        case .eager:     return 2
        case .open:      return 1
        case .selective: return 0
        }
    }
}

struct DateRange: Codable, Hashable, Identifiable, Sendable {
    var start: Date
    var end: Date
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }

    func overlaps(checkIn: Date, checkOut: Date) -> Bool {
        checkIn < end && checkOut > start
    }

    /// Whether `day` falls inside the half-open interval `[start, end)`.
    func contains(_ day: Date) -> Bool {
        day >= start && day < end
    }
}

// MARK: - Nested types

struct Sleeping: Codable, Hashable {
    var numGuestRooms: Int
    // Firestore-compatible [String: Int] map; use sleepingCounts for a typed view.
    var arrangements: [String: Int]

    // MARK: Richer capacity
    // Bathrooms a guest may use. Zero means unsaid; the UI hides the pill rather than guess.
    var numBathrooms: Int = 0
    // Bed sizes counted in `arrangements["bed"]`, keyed by `BedSize.rawValue`;
    // see `bedSizeCounts`. Empty when the host didn't say.
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
            .map { "\($0.value) \($0.key.name(count: $0.value))" }
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

// Fields added after the initial schema use `decodeIfPresent` so older listings
// still decode (a decode failure silently drops the listing from the feed). In
// an extension to keep the memberwise initializer.
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

    // MARK: Accessibility
    // Declared last and defaulted to keep the memberwise initializer working.
    // False means "not stated", never "not accessible", so these are opt-in
    // filters and nothing renders a red X for an absent one.
    var hasStepFreeEntry: Bool = false
    var hasElevator: Bool = false
    var hasAccessibleBathroom: Bool = false

    /// Whether the host claimed any accessibility attribute at all.
    var hasAnyAccessibility: Bool { hasStepFreeEntry || hasElevator || hasAccessibleBathroom }

    /// Backs the "Most Amenities" sort. Accessibility is excluded: it's a fact
    /// about a home, not a perk, and ranking by it would surface listings for
    /// guests who never asked.
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

// Accessibility keys post-date the schema, so older listings must still decode.
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
    // `var` so the edit path can build a Home with an existing id. Treat as
    // immutable after creation; equality depends on it.
    var id: String = UUID().uuidString

    // MARK: Host and location
    var hostUserID: String
    var hostName: String
    // Optional host-chosen label; a host can run several homes in one thread, so
    // a title tells them apart. Nil falls back to "<hostName>'s place" via `displayTitle`.
    var title: String? = nil
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
    // Optional so older listings decode; nil is treated as .flexible.
    var cancellationPolicy: CancellationPolicy? = nil

    // MARK: Photos
    // Optional so pre-photo documents decode; use `photos` for a non-optional view.
    var photoURLs: [String]? = nil

    // MARK: Availability
    // Every day a guest can't have, merged: the host's closed days and accepted
    // stays in one array with nothing marking which is which. Nil or empty means open.
    //
    // The halves live in `homes/{id}/private/availability` (managers only) and
    // are merged before publishing, because this document is readable by the
    // host's friends and Firestore has no field-level rules; publishing both
    // would let a guest learn which nights the home was occupied. Written by
    // whoever last changed either half. It's a display cache; the real
    // double-booking guard is the `acceptStayRequest` transaction.
    var unavailableDateRanges: [DateRange]? = nil

    // MARK: Location coordinates
    // Geocoded at save, then blurred to a neighbourhood (see `approximate(_:)`)
    // since this document is world-readable. Exact coordinates live in the
    // private location subdocument. Nil for older listings.
    var latitude: Double? = nil
    var longitude: Double? = nil

    // MARK: Geohash
    // Indexable geohash of the blurred coordinate, for proximity queries. Nil for
    // older listings or addresses that wouldn't geocode.
    var geohash: String? = nil

    // MARK: Visibility
    // Every listing is friends-only: visible to the host, co-hosts and accepted
    // friends. A friend-of-a-friend sees the host as a suggestion only.
    //
    // Denormalized read ACL (host plus accepted friends): rules can't join to
    // `friendEdges`, so visibility is enforced by querying `allowedViewerIDs
    // contains me`. Written on every save and kept in sync by
    // `onFriendEdgeWritten`. Nil on legacy documents means "host only".
    var allowedViewerIDs: [String]? = nil

    // MARK: Co-hosts
    // Friends the host deputized to keep the listing accurate. They may edit its
    // description and read/write its location and house manual, but not change
    // the host, visibility, roster or delete it; requests still go to the host.
    // `firestore.rules` enforces that boundary; this array is its input.
    var coHostUserIDs: [String]? = nil

    // MARK: Soft delete
    // Nil means active. Set to the server timestamp on delete; HomeStore filters
    // these out while the document is kept for history.
    var deletedAt: Date? = nil

    // MARK: Creation time
    // The feed's recency ordering key, stamped by the repository on create and
    // kept across edits. Documents without it are excluded from the ordered query.
    var createdAt: Date? = nil

    // Identity-based equality and hashing.
    static func == (lhs: Home, rhs: Home) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Non-optional view of photo URLs.
    var photos: [String] { photoURLs ?? [] }

    /// The host's title if set (trimmed, non-empty), for a second line without the fallback.
    var customTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How the listing names itself standing alone: the host's title or "<hostName>'s place".
    var displayTitle: String { customTitle ?? "\(hostName)'s place" }

    /// Every date a guest cannot have, already merged on the wire. Hosts' editors
    /// read the halves from `ListingAvailability`.
    var unavailableRanges: [DateRange] { unavailableDateRanges ?? [] }

    /// Non-optional view of the co-host roster.
    var coHosts: [String] { coHostUserIDs ?? [] }

    /// The most a co-host roster may hold; mirrors `isOptionalList` in `firestore.rules`.
    static let maxCoHosts = 5

    /// Whether `userID` may edit the listing and read its address and manual: the host or a co-host.
    func isManagedBy(_ userID: String) -> Bool {
        guard !userID.isEmpty else { return false }
        return hostUserID == userID || coHosts.contains(userID)
    }

    /// Whether `userID` owns the listing. Only the host may delete it, manage
    /// the roster, or accept a guest.
    func isHostedBy(_ userID: String) -> Bool {
        !userID.isEmpty && hostUserID == userID
    }

    /// The read ACL every listing carries: the host, then accepted friends,
    /// de-duplicated. Shared by the client and the seed script;
    /// `rebuildListingACLs` recomputes it server-side.
    static func viewerIDs(hostUserID: String, friendIDs: some Sequence<String>) -> [String] {
        var seen: Set<String> = []
        return ([hostUserID] + friendIDs).filter { seen.insert($0).inserted }
    }

    /// Decimal places kept on the public coordinate (about a kilometre).
    /// `scripts/seed_test_data.js` applies the same rounding.
    static let publicCoordinatePrecision = 2.0

    /// Blurs an exact coordinate component for the world-readable document.
    static func approximate(_ value: Double) -> Double {
        let scale = pow(10.0, publicCoordinatePrecision)
        return (value * scale).rounded() / scale
    }

    enum CodingKeys: String, CodingKey {
        // `title` must be listed: an explicit CodingKeys drives the encoder too,
        // so omitting it silently dropped titles on save.
        case id, hostUserID, hostName, title, address, description
        case contactPreference, hostContactInfo, hostMotivation
        case sleeping, guestPolicy, amenities
        case cancellationPolicy
        case photoURLs
        case unavailableDateRanges
        case latitude, longitude
        case geohash
        case allowedViewerIDs
        case coHostUserIDs
        case deletedAt
        case createdAt
    }
}

// MARK: - Custom Decodable
extension Home {
    /// The pre-split shape: two public arrays instead of one merged one. Read
    /// only by `decodeUnavailable` and absent from `CodingKeys`, so a save migrates the listing.
    private enum LegacyAvailabilityKeys: String, CodingKey {
        case blockedDateRanges, bookedDateRanges
    }

    /// `unavailableDateRanges` if migrated, otherwise the union of the two legacy
    /// fields. The fallback lets the migration run after the app ships without a
    /// host's blocked week silently reading as open.
    fileprivate static func decodeUnavailable(
        from decoder: Decoder,
        container c: KeyedDecodingContainer<CodingKeys>
    ) throws -> [DateRange]? {
        if let merged = try c.decodeIfPresent([DateRange].self, forKey: .unavailableDateRanges) {
            return merged
        }
        let legacy = try decoder.container(keyedBy: LegacyAvailabilityKeys.self)
        let blocked = try legacy.decodeIfPresent([DateRange].self, forKey: .blockedDateRanges) ?? []
        let booked  = try legacy.decodeIfPresent([DateRange].self, forKey: .bookedDateRanges)  ?? []
        let union = blocked + booked
        return union.isEmpty ? nil : union
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decodeIfPresent(String.self,               forKey: .id)                ?? UUID().uuidString
        hostUserID         = try c.decode(String.self,                         forKey: .hostUserID)
        hostName           = try c.decode(String.self,                         forKey: .hostName)
        title              = try c.decodeIfPresent(String.self,               forKey: .title)
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
        unavailableDateRanges = try Home.decodeUnavailable(from: decoder, container: c)
        latitude            = try c.decodeIfPresent(Double.self,              forKey: .latitude)
        longitude          = try c.decodeIfPresent(Double.self,               forKey: .longitude)
        geohash            = try c.decodeIfPresent(String.self,               forKey: .geohash)
        allowedViewerIDs   = try c.decodeIfPresent([String].self,             forKey: .allowedViewerIDs)
        coHostUserIDs      = try c.decodeIfPresent([String].self,             forKey: .coHostUserIDs)
        deletedAt          = try c.decodeIfPresent(Date.self,                 forKey: .deletedAt)
        createdAt          = try c.decodeIfPresent(Date.self,                 forKey: .createdAt)
    }
}

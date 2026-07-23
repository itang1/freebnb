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

    /// Spelled out rather than assembled. Two of these take -es, and the create
    /// form's steppers appended a bare -s to all five: a host picking where their
    /// guest sleeps was offered "0 couchs" and "0 air mattresss".
    var pluralName: String {
        switch self {
        case .bed:         return "beds"
        case .airMattress: return "air mattresses"
        case .couch:       return "couches"
        case .futon:       return "futons"
        case .floorMat:    return "floor mats"
        }
    }

    /// The form the count calls for. The other half of the same bug: the listing
    /// page's summary never pluralized at all, so two of anything read "2 couch".
    func name(count: Int) -> String { count == 1 ? displayName : pluralName }
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

    /// Phrased for display on a specific listing, since a host's motivation can
    /// differ across homes they list.
    var homeText: String {
        switch self {
        case .eager:     return "I'd love to host at this home"
        case .open:      return "I'm open to hosting at this home"
        case .selective: return "I have limited availability at this home"
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
    // Optional host-chosen label for the listing ("Guest room by the Rose
    // Bowl"). A host may run more than one home and they share a single
    // conversation thread, so a title is what tells two of them apart. Nil (the
    // default, and every listing created before this field existed) falls back
    // to "<hostName>'s place" through `displayTitle`.
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
    // Optional so listings created before this field was added decode cleanly.
    // Nil is treated as .flexible in the UI.
    var cancellationPolicy: CancellationPolicy? = nil

    // MARK: Photos
    // Optional on the wire so documents created before photo support decode
    // cleanly. Access through `photos` for a non-optional view.
    var photoURLs: [String]? = nil

    // MARK: Availability
    // Nil or empty means no blocked dates. The host marks date ranges as blocked;
    // guests cannot request stays that overlap any blocked range. Read reason-free
    // on purpose: "unavailable" never says why, so a host's plans stay their own.
    var blockedDateRanges: [DateRange]? = nil

    // The dates an accepted stay has spoken for. Server-owned: recomputed from the
    // listing's accepted stays by `onStayRequestWritten` and never authored here,
    // so the client only decodes it and rides it back out on save (the repository
    // replaces the whole document, so dropping it would wipe it). A tampered value
    // changes nothing that matters — it is a display cache, and the real
    // double-booking guard lives in the `acceptStayRequest` transaction.
    //
    // Guests see this merged with `blockedDateRanges` into one "unavailable", with
    // no way to tell a booking from a host-blocked day. That is the point: a guest
    // learns a date is taken, never that the home is occupied. Go through
    // `unavailableRanges`, never this, so the two are never shown apart by mistake.
    var bookedDateRanges: [DateRange]? = nil

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
    // Every listing is friends-only: visible to the host, their co-hosts, and
    // the host's accepted friends, and to nobody else. A friend-of-a-friend is
    // shown the host as a friend *suggestion* instead, and sees the listing
    // only after the host accepts them. (A legacy `visibility` tier field used
    // to widen this; it is gone from the model and rejected by the rules.)
    //
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

    /// The host's title only when they actually set one (trimmed, non-empty).
    /// Views that already show the host's name use this to add the title as a
    /// second line without printing the "<host>'s place" fallback.
    var customTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How the listing names itself where it stands alone (chat banner, request
    /// sheet): the host's title if they set one, otherwise "<hostName>'s place".
    /// The single source of truth so those surfaces agree.
    var displayTitle: String { customTitle ?? "\(hostName)'s place" }

    /// Every date a guest cannot have: the host's blocked ranges and the ranges
    /// an accepted stay has taken, together. The one thing guest-facing surfaces
    /// read, so a booked day and a blocked day render identically as "unavailable"
    /// and neither betrays why. A host's own editor keeps them apart (booked is
    /// read-only there), but nowhere a guest can see does.
    var unavailableRanges: [DateRange] {
        (blockedDateRanges ?? []) + (bookedDateRanges ?? [])
    }

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
    /// host may delete the listing, manage the co-host roster, or accept a
    /// guest into the home.
    func isHostedBy(_ userID: String) -> Bool {
        !userID.isEmpty && hostUserID == userID
    }

    /// The read ACL every listing carries: the host, then their accepted friends,
    /// de-duplicated. Kept here so the client write path and the seed script agree
    /// on one definition. `rebuildListingACLs` recomputes the same set server-side
    /// after every save and friend change, repairing any drift.
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
        // `title` belongs here or it is dropped in both directions: an explicit
        // CodingKeys drives the synthesized encoder too, so leaving it out meant
        // a host could name their listing and have the name silently discarded
        // on save, and every listing decoded with a nil title.
        case id, hostUserID, hostName, title, address, description
        case contactPreference, hostContactInfo, hostMotivation
        case sleeping, guestPolicy, amenities
        case cancellationPolicy
        case photoURLs
        case blockedDateRanges
        case bookedDateRanges
        case latitude, longitude
        case geohash
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
        blockedDateRanges   = try c.decodeIfPresent([DateRange].self,         forKey: .blockedDateRanges)
        bookedDateRanges    = try c.decodeIfPresent([DateRange].self,         forKey: .bookedDateRanges)
        latitude            = try c.decodeIfPresent(Double.self,              forKey: .latitude)
        longitude          = try c.decodeIfPresent(Double.self,               forKey: .longitude)
        geohash            = try c.decodeIfPresent(String.self,               forKey: .geohash)
        allowedViewerIDs   = try c.decodeIfPresent([String].self,             forKey: .allowedViewerIDs)
        coHostUserIDs      = try c.decodeIfPresent([String].self,             forKey: .coHostUserIDs)
        deletedAt          = try c.decodeIfPresent(Date.self,                 forKey: .deletedAt)
        createdAt          = try c.decodeIfPresent(Date.self,                 forKey: .createdAt)
    }
}

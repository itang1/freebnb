//
//  ListingDraft.swift
//  freebnb
//
//  An unfinished listing, kept on the device so closing the sheet doesn't throw
//  away ten minutes of typing (feature 13).
//
//  Drafts never leave the phone. A draft holds the street address, which the
//  published listing deliberately does not — the public document carries only
//  city/state/zip, and the street lives in `homes/{id}/private/location`. Writing
//  drafts to Firestore would mean a second home for that street, a second set of
//  rules to get right, and a second thing to delete on account deletion. The
//  device already stores the address the host is typing; keeping it there costs
//  nothing and widens no surface.
//

import Foundation

/// A snapshot of the new-listing form. Every field has the same default the form
/// opens with, so `ListingDraft()` is exactly "nothing typed yet" — which is what
/// makes an untouched form cheap to recognise and refuse to save.
struct ListingDraft: Codable, Equatable, Sendable {
    var street = ""
    var city = ""
    var state = ""
    var zip = ""

    var numGuestRooms = 1
    var numBathrooms = 0
    var maxGuests = 2
    var maxStayDays = 7
    /// Keyed by `SleepingSurface.rawValue`, the same shape `Sleeping.arrangements`
    /// uses. A `[SleepingSurface: Int]` would need `CodingKeyRepresentable` to
    /// survive a round trip through JSON as anything but an array of pairs.
    var sleepingArrangements: [String: Int] = [:]
    /// Keyed by `BedSize.rawValue`, for the same reason.
    var bedSizes: [String: Int] = [:]
    var kidsAllowed = true
    var guestPetsAllowed = false
    var hostHasPets = false

    var hasAC = false
    var hasHeating = false
    var hasKitchen = false
    var hasFridgeSpace = false
    var hasMicrowave = false
    var hasTV = false
    var hasWifi = false

    var hasPrivateGuestBathroom = false
    var parkingDetails = ""
    var hasInUnitLaundry = false
    var hasCoinLaundryNearby = false

    var hasStepFreeEntry = false
    var hasElevator = false
    var hasAccessibleBathroom = false

    var providesPillows = false
    var providesBlankets = false
    var providesTowels = false
    var providesToiletries = false
    var foodProvision: FoodProvision = .none

    var title = ""
    /// Whether `title` is the host's own wording or just the name the form
    /// suggested. Restoring a draft has to tell them apart: a suggested name
    /// should keep tracking the city, and a typed one must never be overwritten.
    /// Defaults to false, so drafts stored before this field decode as suggested,
    /// which is the recoverable direction to be wrong in.
    var titleWasEdited = false
    var description = ""
    var contactPreference: HostContactPreference = .inApp
    var hostContactInfo = ""
    var hostMotivation: HostMotivation = .open
    var cancellationPolicy: CancellationPolicy = .flexible

    /// True when the host has typed nothing. Such a draft is not worth storing,
    /// and restoring one would announce a "draft" that says nothing.
    ///
    /// A suggested listing name doesn't count as typing: the form fills one in
    /// the moment it opens, and without this exception simply opening the sheet
    /// and closing it would leave a draft claiming work was in progress.
    var isPristine: Bool {
        var baseline = ListingDraft()
        if !titleWasEdited { baseline.title = title }
        return self == baseline
    }

    /// Typed view of the sleeping arrangements. Both directions drop raw values
    /// that no longer name a surface and counts that aren't positive, so that
    /// `draft.sleepingCounts = x; draft.sleepingCounts` returns `x` and a pristine
    /// draft stays recognisably pristine.
    var sleepingCounts: [SleepingSurface: Int] {
        get {
            sleepingArrangements.reduce(into: [:]) { result, pair in
                if let surface = SleepingSurface(rawValue: pair.key), pair.value > 0 {
                    result[surface] = pair.value
                }
            }
        }
        set {
            sleepingArrangements = newValue.reduce(into: [:]) { result, pair in
                if pair.value > 0 { result[pair.key.rawValue] = pair.value }
            }
        }
    }

    /// Typed view of the bed sizes, with the same round-trip guarantee.
    var bedSizeCounts: [BedSize: Int] {
        get {
            bedSizes.reduce(into: [:]) { result, pair in
                if let size = BedSize(rawValue: pair.key), pair.value > 0 {
                    result[size] = pair.value
                }
            }
        }
        set {
            bedSizes = newValue.reduce(into: [:]) { result, pair in
                if pair.value > 0 { result[pair.key.rawValue] = pair.value }
            }
        }
    }
}

/// Reads and writes the single in-progress draft for one user.
///
/// Keyed by user id, so signing into a second account on a shared device does not
/// surface the first host's half-typed address. An empty user id (a signed-out or
/// anonymous session) stores nothing.
struct ListingDraftStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ userID: String) -> String { "listingDraft.\(userID)" }

    /// Nil when there is no draft, when it decodes to nothing usable, or when it
    /// was never really started. A draft that fails to decode is discarded rather
    /// than surfaced as an error: it is a convenience, and the form behind it is
    /// perfectly usable empty.
    func load(userID: String) -> ListingDraft? {
        guard !userID.isEmpty,
              let data = defaults.data(forKey: key(userID)),
              let draft = try? JSONDecoder().decode(ListingDraft.self, from: data),
              !draft.isPristine
        else { return nil }
        return draft
    }

    /// Storing a pristine draft clears any previous one: the host emptied the
    /// form, and offering to restore what they just cleared would be perverse.
    func save(_ draft: ListingDraft, userID: String) {
        guard !userID.isEmpty else { return }
        guard !draft.isPristine else {
            clear(userID: userID)
            return
        }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key(userID))
    }

    func clear(userID: String) {
        guard !userID.isEmpty else { return }
        defaults.removeObject(forKey: key(userID))
    }
}

/// What the listing form is for. The two axes that matter are which listing seeds
/// the fields, and which listing (if any) the save overwrites — and duplication
/// is precisely the case where those differ.
enum ListingFormMode: Hashable {
    case create
    case edit(Home)
    /// Prefilled from an existing listing, saved as a new one. For the host with a
    /// guest room and a couch, who should not retype their address (feature 13).
    case duplicate(Home)

    /// The listing whose values the form opens with.
    var source: Home? {
        switch self {
        case .create:                            return nil
        case .edit(let home), .duplicate(let home): return home
        }
    }

    /// The listing this save overwrites, or nil when it writes a new document.
    /// `duplicate` deliberately returns nil: it keeps the source's fields and
    /// none of its identity.
    var target: Home? {
        guard case .edit(let home) = self else { return nil }
        return home
    }

    /// Only a from-scratch listing is draft-backed. An edit has a saved document
    /// behind it, and a duplicate is one tap away from being recreated — restoring
    /// an unrelated draft over either would overwrite what the host just asked for.
    var isDraftBacked: Bool {
        if case .create = self { return true }
        return false
    }

    var navigationTitle: String {
        switch self {
        case .create:    return "New Listing"
        case .edit:      return "Edit Listing"
        case .duplicate: return "Duplicate Listing"
        }
    }
}

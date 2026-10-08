//
//  ListingDraft.swift
//  freebnb
//
//  An unfinished listing kept on the device so closing the sheet doesn't lose the typing.
//
//  Drafts never leave the phone. A draft holds the street address, which the public
//  listing deliberately lacks (it lives in `homes/{id}/private/location`); syncing
//  drafts would add a second home for it, more rules, and another account-deletion cleanup.
//

import Foundation

/// A snapshot of the new-listing form. Defaults match the form's opening state, so `ListingDraft()` is
/// "nothing typed" and untouched forms are easy to refuse.
struct ListingDraft: Codable, Equatable, Sendable {
    var street = ""
    var city = ""
    var state = ""
    var zip = ""

    var numGuestRooms = 1
    var numBathrooms = 0
    var maxGuests = 2
    var maxStayDays = 7
    /// Keyed by `SleepingSurface.rawValue`, like `Sleeping.arrangements`; an enum-keyed dictionary wouldn't
    /// round-trip through JSON as a map.
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
    /// Whether `title` is the host's wording or the form's suggestion, which a restore must distinguish
    /// (suggestions keep tracking the city). Defaults to false so older drafts decode as suggested, the
    /// recoverable direction.
    var titleWasEdited = false
    var description = ""
    var contactPreference: HostContactPreference = .inApp
    var hostContactInfo = ""
    var hostMotivation: HostMotivation = .open
    var cancellationPolicy: CancellationPolicy = .flexible

    /// True when the host has typed nothing, so the draft isn't worth storing. A
    /// suggested name doesn't count, or opening and closing the sheet would leave a draft.
    var isPristine: Bool {
        var baseline = ListingDraft()
        if !titleWasEdited { baseline.title = title }
        return self == baseline
    }

    /// Typed view of the sleeping arrangements. Both directions drop unknown surfaces and non-positive
    /// counts, so setting then reading round-trips and a pristine draft stays pristine.
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

/// Reads and writes the one in-progress draft per user. Keyed by user id so a shared device
/// doesn't surface another host's address; an empty id (signed out or anonymous) stores nothing.
struct ListingDraftStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ userID: String) -> String { "listingDraft.\(userID)" }

    /// Nil when there's no draft, it decodes to nothing usable, or it was never started.
    /// An undecodable draft is discarded, not surfaced, since the form works empty.
    func load(userID: String) -> ListingDraft? {
        guard !userID.isEmpty,
              let data = defaults.data(forKey: key(userID)),
              let draft = try? JSONDecoder().decode(ListingDraft.self, from: data),
              !draft.isPristine
        else { return nil }
        return draft
    }

    /// Storing a pristine draft clears the previous one; restoring what the host just cleared would be perverse.
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

/// What the listing form is for. The axes are which listing seeds the fields and which (if any) the save
/// overwrites; duplication is where they differ.
enum ListingFormMode: Hashable {
    case create
    case edit(Home)
    /// Prefilled from an existing listing, saved as new, so a host with several rooms needn't retype their
    /// address.
    case duplicate(Home)

    /// The listing whose values the form opens with.
    var source: Home? {
        switch self {
        case .create:                            return nil
        case .edit(let home), .duplicate(let home): return home
        }
    }

    /// The listing this save overwrites, or nil for a new document; `duplicate` keeps fields but none of the
    /// identity.
    var target: Home? {
        guard case .edit(let home) = self else { return nil }
        return home
    }

    /// Only a from-scratch listing is draft-backed; restoring an unrelated draft over an edit or duplicate
    /// would overwrite what the host asked for.
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

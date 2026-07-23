//
//  CreateListingViewModel.swift
//  freebnb
//
//  Form state and save pipeline for creating, editing, or duplicating a
//  listing. Split from CreateListingPage.swift so the 400-line model and the
//  400-line form type-check in parallel.
//

import CoreLocation
import Observation


@MainActor
@Observable
final class CreateListingViewModel {
    // Whether the form creates, edits, or duplicates. `mode.source` seeds the
    // fields; `mode.target` is the listing a save overwrites, and is nil for both
    // create and duplicate.
    let mode: ListingFormMode

    // Location
    var street: String
    var city: String
    var stateField: String
    var zip: String

    // Capacity
    var numGuestRooms: Int
    var numBathrooms: Int
    var maxGuests: Int
    var maxStayDays: Int
    var sleepingCounts: [SleepingSurface: Int]
    var bedSizeCounts: [BedSize: Int]
    var kidsAllowed: Bool
    var guestPetsAllowed: Bool
    var hostHasPets: Bool

    // Amenities
    var hasAC: Bool
    var hasHeating: Bool
    var hasKitchen: Bool
    var hasFridgeSpace: Bool
    var hasMicrowave: Bool
    var hasTV: Bool
    var hasWifi: Bool

    // Rooms and laundry
    var hasPrivateGuestBathroom: Bool
    var parkingDetails: String
    var hasInUnitLaundry: Bool
    var hasCoinLaundryNearby: Bool

    // Accessibility
    var hasStepFreeEntry: Bool
    var hasElevator: Bool
    var hasAccessibleBathroom: Bool

    // Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    var foodProvision: FoodProvision

    // Host and contact
    // Optional short label so a host running more than one home can tell them
    // apart; blank means "use <hostName>'s place" (see Home.displayTitle).
    var title: String
    var description: String
    var contactPreference: HostContactPreference
    var hostContactInfo: String
    var hostMotivation: HostMotivation
    var cancellationPolicy: CancellationPolicy

    // Save state
    var isSaving = false
    var errorMessage: String?
    // Set when geocoding the address returned nothing. The listing is still
    // saveable without a map pin, but the host is told rather than left to
    // wonder why their listing never shows on the map (L6).
    var geocodeFailed = false
    // True once an unfinished draft has been restored into this form, so the view
    // can say so and offer a way out of it (feature 13).
    var restoredDraft = false

    init(mode: ListingFormMode = .create) {
        self.mode = mode
        let source = mode.source
        // The street is not on the public listing document; when a listing seeds
        // the form it has to be loaded from the private location subdoc (see
        // `loadStreet`). Until it arrives `canSave` is false, so an edit can never
        // blank out the address.
        street = ""
        city = source?.address.city ?? ""
        stateField = source?.address.state ?? ""
        zip = source?.address.zip ?? ""
        numGuestRooms = source?.sleeping.numGuestRooms ?? 1
        numBathrooms = source?.sleeping.numBathrooms ?? 0
        maxGuests = source?.guestPolicy.maxGuests ?? 2
        maxStayDays = source?.guestPolicy.maxStayDays ?? 7
        sleepingCounts = source?.sleeping.sleepingCounts ?? [:]
        bedSizeCounts = source?.sleeping.bedSizeCounts ?? [:]
        kidsAllowed = source?.guestPolicy.kidsAllowed ?? true
        guestPetsAllowed = source?.guestPolicy.guestPetsAllowed ?? false
        hostHasPets = source?.amenities.hostHasPets ?? false
        hasAC = source?.amenities.hasAC ?? false
        hasHeating = source?.amenities.hasHeating ?? false
        hasKitchen = source?.amenities.hasKitchen ?? false
        hasFridgeSpace = source?.amenities.hasFridgeSpace ?? false
        hasMicrowave = source?.amenities.hasMicrowave ?? false
        hasTV = source?.amenities.hasTV ?? false
        hasWifi = source?.amenities.hasWifi ?? false
        hasPrivateGuestBathroom = source?.amenities.hasPrivateGuestBathroom ?? false
        parkingDetails = source?.amenities.parkingDetails ?? ""
        hasInUnitLaundry = source?.amenities.hasInUnitLaundry ?? false
        hasCoinLaundryNearby = source?.amenities.hasCoinLaundryNearby ?? false
        hasStepFreeEntry = source?.amenities.hasStepFreeEntry ?? false
        hasElevator = source?.amenities.hasElevator ?? false
        hasAccessibleBathroom = source?.amenities.hasAccessibleBathroom ?? false
        providesPillows = source?.amenities.providesPillows ?? false
        providesBlankets = source?.amenities.providesBlankets ?? false
        providesTowels = source?.amenities.providesTowels ?? false
        providesToiletries = source?.amenities.providesToiletries ?? false
        foodProvision = source?.amenities.foodProvision ?? .none
        title = source?.title ?? ""
        // An edit keeps the name the host already chose. A duplicate must not:
        // the copy would collide with the listing it came from, so it starts
        // untouched and takes a fresh suggestion instead.
        if case .edit = mode, source?.title?.isEmpty == false {
            titleWasEdited = true
        }
        description = source?.description ?? ""
        contactPreference = source?.contactPreference ?? .inApp
        hostContactInfo = source?.hostContactInfo ?? ""
        hostMotivation = source?.hostMotivation ?? .open
        cancellationPolicy = source?.cancellationPolicy ?? .flexible
    }

    /// Pulls the street address of the listing seeding the form out of its private
    /// location document. A host always has read access to their own — and both an
    /// edit and a duplicate are of the host's own listing.
    ///
    /// No-ops once `street` is set, which is what lets a restored draft's address
    /// survive this call.
    func loadStreet(homeStore: HomeStore) async {
        guard let source = mode.source, street.isEmpty else { return }
        street = await homeStore.location(for: source.id)?.street ?? ""
    }

    // MARK: - Drafts (feature 13)

    /// The form as a storable snapshot, and the inverse. Kept adjacent so a field
    /// added to one is conspicuously missing from the other.
    var draft: ListingDraft {
        get {
            var draft = ListingDraft()
            draft.street = street
            draft.city = city
            draft.state = stateField
            draft.zip = zip
            draft.numGuestRooms = numGuestRooms
            draft.numBathrooms = numBathrooms
            draft.maxGuests = maxGuests
            draft.maxStayDays = maxStayDays
            draft.sleepingCounts = sleepingCounts
            draft.bedSizeCounts = bedSizeCounts
            draft.kidsAllowed = kidsAllowed
            draft.guestPetsAllowed = guestPetsAllowed
            draft.hostHasPets = hostHasPets
            draft.hasAC = hasAC
            draft.hasHeating = hasHeating
            draft.hasKitchen = hasKitchen
            draft.hasFridgeSpace = hasFridgeSpace
            draft.hasMicrowave = hasMicrowave
            draft.hasTV = hasTV
            draft.hasWifi = hasWifi
            draft.hasPrivateGuestBathroom = hasPrivateGuestBathroom
            draft.parkingDetails = parkingDetails
            draft.hasInUnitLaundry = hasInUnitLaundry
            draft.hasCoinLaundryNearby = hasCoinLaundryNearby
            draft.hasStepFreeEntry = hasStepFreeEntry
            draft.hasElevator = hasElevator
            draft.hasAccessibleBathroom = hasAccessibleBathroom
            draft.providesPillows = providesPillows
            draft.providesBlankets = providesBlankets
            draft.providesTowels = providesTowels
            draft.providesToiletries = providesToiletries
            draft.foodProvision = foodProvision
            draft.title = title
            draft.titleWasEdited = titleWasEdited
            draft.description = description
            draft.contactPreference = contactPreference
            draft.hostContactInfo = hostContactInfo
            draft.hostMotivation = hostMotivation
            draft.cancellationPolicy = cancellationPolicy
            return draft
        }
        set {
            street = newValue.street
            city = newValue.city
            stateField = newValue.state
            zip = newValue.zip
            numGuestRooms = newValue.numGuestRooms
            numBathrooms = newValue.numBathrooms
            maxGuests = newValue.maxGuests
            maxStayDays = newValue.maxStayDays
            sleepingCounts = newValue.sleepingCounts
            bedSizeCounts = newValue.bedSizeCounts
            kidsAllowed = newValue.kidsAllowed
            guestPetsAllowed = newValue.guestPetsAllowed
            hostHasPets = newValue.hostHasPets
            hasAC = newValue.hasAC
            hasHeating = newValue.hasHeating
            hasKitchen = newValue.hasKitchen
            hasFridgeSpace = newValue.hasFridgeSpace
            hasMicrowave = newValue.hasMicrowave
            hasTV = newValue.hasTV
            hasWifi = newValue.hasWifi
            hasPrivateGuestBathroom = newValue.hasPrivateGuestBathroom
            parkingDetails = newValue.parkingDetails
            hasInUnitLaundry = newValue.hasInUnitLaundry
            hasCoinLaundryNearby = newValue.hasCoinLaundryNearby
            hasStepFreeEntry = newValue.hasStepFreeEntry
            hasElevator = newValue.hasElevator
            hasAccessibleBathroom = newValue.hasAccessibleBathroom
            providesPillows = newValue.providesPillows
            providesBlankets = newValue.providesBlankets
            providesTowels = newValue.providesTowels
            providesToiletries = newValue.providesToiletries
            foodProvision = newValue.foodProvision
            title = newValue.title
            titleWasEdited = newValue.titleWasEdited
            description = newValue.description
            contactPreference = newValue.contactPreference
            hostContactInfo = newValue.hostContactInfo
            hostMotivation = newValue.hostMotivation
            cancellationPolicy = newValue.cancellationPolicy
        }
    }

    /// Restores an unfinished from-scratch listing, if one is stored. Called once,
    /// before `loadStreet`, so a restored address is not overwritten.
    func restoreDraft(from store: ListingDraftStore, userID: String) {
        guard mode.isDraftBacked, let stored = store.load(userID: userID) else { return }
        draft = stored
        restoredDraft = true
    }

    func persistDraft(to store: ListingDraftStore, userID: String) {
        guard mode.isDraftBacked else { return }
        store.save(draft, userID: userID)
    }

    /// Empties the form and forgets the draft behind it.
    func discardDraft(from store: ListingDraftStore, userID: String) {
        draft = ListingDraft()
        restoredDraft = false
        store.clear(userID: userID)
    }

    /// Cap on the optional listing title. Mirrors `isOptionalString(data,
    /// 'title', 60)` in firestore.rules, which is what actually enforces it; the
    /// client checks the same bound so a save never round-trips only to bounce.
    static let titleMaxLength = 60

    /// The title, trimmed, or nil when the host left it blank.
    var trimmedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every listing needs a name, so the form fills one in and the host only
    /// types if they want something better. Suggestions stop the moment they do:
    /// `titleWasEdited` latches on the first keystroke and never unlatches, so
    /// nothing the form computes later overwrites what they wrote.
    var titleWasEdited = false

    /// The suggested name for this listing: "<Host>'s Place in <City>", made
    /// distinct when the host already used that name for another home. A second
    /// place in a new city is distinct on the city alone; a second place in the
    /// same city takes an ordinal ("<Host>'s Second Place in Pasadena").
    ///
    /// `taken` is the host's other listing titles, which is why this can't be a
    /// plain computed property: only the view can see them.
    func suggestedTitle(hostName: String, taken: Set<String>) -> String {
        let name = hostName.trimmingCharacters(in: .whitespaces)
        let place = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        let suffix = place.isEmpty ? "" : " in \(place)"
        let lowercasedTaken = Set(taken.map { $0.lowercased() })

        let plain = "\(name)'s Place\(suffix)"
        if !lowercasedTaken.contains(plain.lowercased()) { return plain }

        // Ordinals read better than "(2)" for the handful of homes anyone
        // realistically lists; past that, fall back to counting.
        let ordinals = ["Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth"]
        for ordinal in ordinals {
            let candidate = "\(name)'s \(ordinal) Place\(suffix)"
            if !lowercasedTaken.contains(candidate.lowercased()) { return candidate }
        }
        var n = ordinals.count + 2
        while lowercasedTaken.contains("\(plain) (\(n))".lowercased()) { n += 1 }
        return "\(plain) (\(n))"
    }

    /// The last value this form wrote into `title` itself, so `noteTitleChanged`
    /// can tell the host's typing apart from its own suggestion.
    private var lastSuggestion: String?

    /// Fills in a suggested title, unless the host has already typed one. Called
    /// as the form loads and as the city changes, so the suggestion tracks the
    /// address until the moment the host takes the field over.
    func applySuggestedTitleIfUntouched(hostName: String, taken: Set<String>) {
        guard !titleWasEdited else { return }
        let suggestion = suggestedTitle(hostName: hostName, taken: taken)
        guard suggestion != title else { return }
        title = suggestion
        lastSuggestion = suggestion
    }

    /// Call when the title field changes. Latches `titleWasEdited` only for a
    /// change this form didn't make, so applying a suggestion doesn't count as
    /// the host editing it and stop later suggestions.
    func noteTitleChanged() {
        if title != lastSuggestion { titleWasEdited = true }
    }

    /// Why a title is not acceptable, or nil when it is. `taken` is the host's
    /// other listings' titles; two homes sharing a name would leave the request
    /// sheet and the chat banner unable to say which is which, which is the whole
    /// point of the field.
    func titleProblem(taken: Set<String>) -> String? {
        guard let trimmed = trimmedTitle else {
            return "Give this listing a name so you and your guests can tell it from your other homes."
        }
        if trimmed.count > Self.titleMaxLength {
            return "Keep it under \(Self.titleMaxLength) characters."
        }
        if taken.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "You already have a listing called that. Give this one a different name."
        }
        return nil
    }

    /// `taken` comes from the view, which is the only side that can see the
    /// host's other listings.
    func canSave(displayName: String, takenTitles: Set<String> = []) -> Bool {
        guard !isSaving else { return false }
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard titleProblem(taken: takenTitles) == nil else { return false }
        guard !street.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !city.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !stateField.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !zip.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !sleepingCounts.isEmpty else { return false }
        if contactPreference == .contactInfo,
           hostContactInfo.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    /// Persists the listing. Returns `true` when the sheet should dismiss.
    ///
    /// When geocoding the address fails and `allowMissingCoordinates` is false,
    /// nothing is written: `geocodeFailed` is set and the view offers the host a
    /// retry or an explicit "save without a map pin". Passing
    /// `allowMissingCoordinates: true` is that second choice.
    @discardableResult
    func save(
        homeStore: HomeStore,
        hostUserID: String,
        hostName: String,
        friendIDs: [String],
        allowMissingCoordinates: Bool = false
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        geocodeFailed = false
        defer { isSaving = false }

        let trimmedStreet = street.trimmingCharacters(in: .whitespaces)
        var home = makeHome(hostUserID: hostUserID, hostName: hostName, friendIDs: friendIDs)

        // Geocode so the map view can place a pin. The exact coordinate is private
        // — publishing it would give away the street the address split just hid —
        // so the listing document carries a rounded copy. Routed through the
        // shared cache (not a fresh CLGeocoder) so browsing and re-saves respect
        // CLGeocoder's rate limit (L6).
        let addressString = "\(trimmedStreet), \(city.trimmingCharacters(in: .whitespaces)), \(stateField.trimmingCharacters(in: .whitespaces)) \(zip.trimmingCharacters(in: .whitespaces))"
        var location = ListingLocation(street: trimmedStreet, latitude: nil, longitude: nil)
        do {
            let coordinate = try await GeocodingCache.shared.coordinate(for: addressString)
            location.latitude  = coordinate.latitude
            location.longitude = coordinate.longitude
            home.latitude  = Home.approximate(coordinate.latitude)
            home.longitude = Home.approximate(coordinate.longitude)
            // Index the blurred coordinate for proximity queries (feature 11).
            if let lat = home.latitude, let lon = home.longitude {
                home.geohash = Geohash.encode(latitude: lat, longitude: lon)
            }
        } catch {
            // Don't save a listing with no coordinates behind the host's back.
            // Surface the failure so they can fix the address and retry, or
            // knowingly save without a map pin.
            guard allowMissingCoordinates else {
                geocodeFailed = true
                return false
            }
        }

        do {
            try await homeStore.save(home, location: location)
            Telemetry.log(.createListingCompleted, parameters: ["is_edit": mode.target != nil])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Builds the `Home` document a save would write: the form fields, the read
    /// ACL, and (when editing) every stored field the form does not manage.
    /// Split out of `save` so the assembly is testable without geocoding or
    /// persistence, and so each function stays within lint's length limit.
    /// Internal, not private, for exactly that testability.
    func makeHome(hostUserID: String, hostName: String, friendIDs: [String]) -> Home {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactInfo = hostContactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepingRaw = sleepingCounts.reduce(into: [String: Int]()) { acc, pair in
            acc[pair.key.rawValue] = pair.value
        }
        // Bed sizes describe the beds in `sleepingRaw`, so they are dropped along
        // with the beds. Leaving "1 queen" on a listing whose last bed just became
        // a couch would be a claim the arrangements contradict (feature 17).
        let bedSizesRaw = (sleepingCounts[.bed] ?? 0) > 0
            ? bedSizeCounts.reduce(into: [String: Int]()) { acc, pair in acc[pair.key.rawValue] = pair.value }
            : [:]

        var home = Home(
            hostUserID: hostUserID,
            hostName: hostName,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            // Street deliberately absent: it goes to the private location doc below.
            address: Address(
                city: city.trimmingCharacters(in: .whitespaces),
                state: stateField.trimmingCharacters(in: .whitespaces),
                zip: zip.trimmingCharacters(in: .whitespaces)
            ),
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            contactPreference: contactPreference,
            hostContactInfo: contactPreference == .contactInfo && !trimmedContactInfo.isEmpty ? trimmedContactInfo : nil,
            hostMotivation: hostMotivation,
            sleeping: Sleeping(
                numGuestRooms: numGuestRooms,
                arrangements: sleepingRaw,
                numBathrooms: numBathrooms,
                bedSizes: bedSizesRaw
            ),
            guestPolicy: GuestPolicy(
                maxGuests: maxGuests,
                maxStayDays: maxStayDays,
                kidsAllowed: kidsAllowed,
                guestPetsAllowed: guestPetsAllowed
            ),
            amenities: Amenities(
                hasAC: hasAC,
                hasHeating: hasHeating,
                hasKitchen: hasKitchen,
                hasFridgeSpace: hasFridgeSpace,
                hasMicrowave: hasMicrowave,
                hasTV: hasTV,
                hasWifi: hasWifi,
                hasPrivateGuestBathroom: hasPrivateGuestBathroom,
                hostHasPets: hostHasPets,
                parkingDetails: parkingDetails.trimmingCharacters(in: .whitespacesAndNewlines),
                hasInUnitLaundry: hasInUnitLaundry,
                hasCoinLaundryNearby: hasCoinLaundryNearby,
                providesPillows: providesPillows,
                providesBlankets: providesBlankets,
                providesTowels: providesTowels,
                providesToiletries: providesToiletries,
                foodProvision: foodProvision,
                hasStepFreeEntry: hasStepFreeEntry,
                hasElevator: hasElevator,
                hasAccessibleBathroom: hasAccessibleBathroom
            ),
            cancellationPolicy: cancellationPolicy
        )

        // Recomputed on every save rather than carried over from `editing`, so an
        // edit picks up friends added since the listing was created. The
        // `onFriendEdgeWritten` function keeps it current between saves.
        home.allowedViewerIDs = Home.viewerIDs(hostUserID: hostUserID, friendIDs: friendIDs)

        // Preserve identity and creation time when editing so an edit keeps the
        // listing's feed position instead of jumping to the top (L3). A duplicate
        // has no target, so it keeps neither: it is a new listing that happens to
        // start out looking like an old one, and it belongs at the top of the feed.
        if let existing = mode.target {
            home.id = existing.id
            home.createdAt = existing.createdAt
            // The roster is never rewritten by an edit. Only `HomeStore.addCoHost`
            // and `removeCoHost` touch it, one addition per write, because that is
            // all a loop-free rule can check against the friend graph.
            home.coHostUserIDs = existing.coHostUserIDs
            // The form has no photo or availability controls, and the repository
            // save is a full-document overwrite: anything not carried over here is
            // erased from the stored listing. Losing these would silently reopen
            // every date the availability editor blocked, drop the bookings the
            // server had filled in (until the next stay change rewrote them), and
            // strip the listing's photos.
            home.photoURLs = existing.photoURLs
            // The merged calendar the public document publishes. Its two halves
            // live in `homes/{id}/private/availability` and this form never
            // touches them, but the published union still has to survive a
            // full-document overwrite: dropping it would silently reopen every day
            // the host had closed and every night an accepted stay had taken, and
            // nothing would rewrite it until the next stay change or availability
            // edit.
            home.unavailableDateRanges = existing.unavailableDateRanges

            // A co-host is editing (feature 14). Every field `firestore.rules`
            // pins to the host is carried over from the stored listing rather than
            // rebuilt from this session. Two of these would otherwise be actively
            // wrong, not merely rejected: `hostName` would become the co-host's own
            // name, and `allowedViewerIDs` (recomputed above from the *saving*
            // user's friends) would republish a friends-only listing to the
            // co-host's social graph. The rules reject the write either way; this
            // is what stops it from being attempted.
            if !existing.isHostedBy(hostUserID) {
                home.hostUserID = existing.hostUserID
                home.hostName = existing.hostName
                home.address = existing.address
                home.contactPreference = existing.contactPreference
                home.hostContactInfo = existing.hostContactInfo
                home.allowedViewerIDs = existing.allowedViewerIDs
            }
        }
        return home
    }
}

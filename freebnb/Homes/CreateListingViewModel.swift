//
//  CreateListingViewModel.swift
//  freebnb
//
//  Form state and save pipeline for creating, editing or duplicating a listing.
//  Split from CreateListingPage.swift so the two type-check in parallel.
//

import CoreLocation
import Observation


@MainActor
@Observable
final class CreateListingViewModel {
    // Create, edit or duplicate. `mode.source` seeds the fields; `mode.target` is
    // the listing a save overwrites (nil for create and duplicate).
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
    // Optional short label to tell a host's homes apart; blank means "<hostName>'s place".
    var title: String
    var description: String
    var contactPreference: HostContactPreference
    var hostContactInfo: String
    var hostMotivation: HostMotivation
    var cancellationPolicy: CancellationPolicy

    // Save state
    var isSaving = false
    var errorMessage: String?
    // Set when geocoding found nothing. The listing can still save without a pin,
    // but the host is told.
    var geocodeFailed = false
    // True once an unfinished draft was restored, so the view can say so and offer a way out.
    var restoredDraft = false

    init(mode: ListingFormMode = .create) {
        self.mode = mode
        let source = mode.source
        // The street isn't on the public document; it loads from the private
        // location subdoc (`loadStreet`), and `canSave` stays false until then so an edit can't blank it.
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
        // An edit keeps its name; a duplicate starts fresh and takes a new suggestion.
        if case .edit = mode, source?.title?.isEmpty == false {
            titleWasEdited = true
        }
        description = source?.description ?? ""
        contactPreference = source?.contactPreference ?? .inApp
        hostContactInfo = source?.hostContactInfo ?? ""
        hostMotivation = source?.hostMotivation ?? .open
        cancellationPolicy = source?.cancellationPolicy ?? .flexible
    }

    /// Loads the street from the seed listing's private location document (the
    /// host can always read their own). No-ops once `street` is set, so a restored draft's address survives.
    func loadStreet(homeStore: HomeStore) async {
        guard let source = mode.source, street.isEmpty else { return }
        street = await homeStore.location(for: source.id)?.street ?? ""
    }

    // MARK: - Drafts

    /// The form as a storable snapshot, and the inverse; keep them adjacent so a missing field stands out.
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

    /// Restores an unfinished from-scratch listing, if stored. Call before `loadStreet`.
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

    /// Cap on the optional title; mirrors `isOptionalString(data, 'title', 60)` in firestore.rules.
    static let titleMaxLength = 60

    /// The title, trimmed, or nil when the host left it blank.
    var trimmedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every listing needs a name, so the form suggests one. Suggestions stop at
    /// the host's first keystroke (`titleWasEdited` never unlatches).
    var titleWasEdited = false

    /// The suggested name: "<Host>'s Place in <City>", made distinct from the
    /// host's other titles (`taken`, which only the view can see) with an ordinal
    /// when the city repeats ("<Host>'s Second Place in Pasadena").
    func suggestedTitle(hostName: String, taken: Set<String>) -> String {
        let name = hostName.trimmingCharacters(in: .whitespaces)
        let place = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        let suffix = place.isEmpty ? "" : " in \(place)"
        let lowercasedTaken = Set(taken.map { $0.lowercased() })

        let plain = "\(name)'s Place\(suffix)"
        if !lowercasedTaken.contains(plain.lowercased()) { return plain }

        // Ordinals read better than "(2)" for realistic counts; past that, count.
        let ordinals = ["Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth"]
        for ordinal in ordinals {
            let candidate = "\(name)'s \(ordinal) Place\(suffix)"
            if !lowercasedTaken.contains(candidate.lowercased()) { return candidate }
        }
        var n = ordinals.count + 2
        while lowercasedTaken.contains("\(plain) (\(n))".lowercased()) { n += 1 }
        return "\(plain) (\(n))"
    }

    /// The last value this form wrote into `title`, to tell typing from its own suggestion.
    private var lastSuggestion: String?

    /// Fills in a suggested title unless the host already typed one; tracks the city until then.
    func applySuggestedTitleIfUntouched(hostName: String, taken: Set<String>) {
        guard !titleWasEdited else { return }
        let suggestion = suggestedTitle(hostName: hostName, taken: taken)
        guard suggestion != title else { return }
        title = suggestion
        lastSuggestion = suggestion
    }

    /// Call when the title changes. Latches `titleWasEdited` only for changes this form didn't make.
    func noteTitleChanged() {
        if title != lastSuggestion { titleWasEdited = true }
    }

    /// Why a title is unacceptable, or nil. `taken` is the host's other titles;
    /// duplicates would leave the request sheet and chat banner ambiguous.
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

    /// `taken` comes from the view, which can see the host's other listings.
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

    /// Persists the listing; true when the sheet should dismiss. If geocoding
    /// fails and `allowMissingCoordinates` is false, nothing is written and
    /// `geocodeFailed` is set so the view can offer a retry or "save without a map pin".
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

        // Geocode for the map pin via the shared cache (respecting CLGeocoder's rate
        // limit). The listing carries a rounded copy; the exact one stays private.
        let addressString = "\(trimmedStreet), \(city.trimmingCharacters(in: .whitespaces)), \(stateField.trimmingCharacters(in: .whitespaces)) \(zip.trimmingCharacters(in: .whitespaces))"
        var location = ListingLocation(street: trimmedStreet, latitude: nil, longitude: nil)
        do {
            let coordinate = try await GeocodingCache.shared.coordinate(for: addressString)
            location.latitude  = coordinate.latitude
            location.longitude = coordinate.longitude
            home.latitude  = Home.approximate(coordinate.latitude)
            home.longitude = Home.approximate(coordinate.longitude)
            // Index the blurred coordinate for proximity queries.
            if let lat = home.latitude, let lon = home.longitude {
                home.geohash = Geohash.encode(latitude: lat, longitude: lon)
            }
        } catch {
            // Don't save without coordinates behind the host's back; surface the failure.
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

    /// Builds the `Home` a save would write: form fields, read ACL and (when
    /// editing) stored fields the form doesn't manage. Internal for testability.
    func makeHome(hostUserID: String, hostName: String, friendIDs: [String]) -> Home {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactInfo = hostContactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepingRaw = sleepingCounts.reduce(into: [String: Int]()) { acc, pair in
            acc[pair.key.rawValue] = pair.value
        }
        // Bed sizes describe the beds in `sleepingRaw`; drop them with the beds.
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

        // Recomputed every save so an edit picks up friends added since creation.
        home.allowedViewerIDs = Home.viewerIDs(hostUserID: hostUserID, friendIDs: friendIDs)

        // Editing preserves identity and creation time (feed position); a duplicate keeps neither.
        if let existing = mode.target {
            home.id = existing.id
            home.createdAt = existing.createdAt
            // Edits never rewrite the roster; only `HomeStore.addCoHost`/`removeCoHost`
            // do, one addition per write, as the loop-free rule requires.
            home.coHostUserIDs = existing.coHostUserIDs
            // The form has no photo or availability controls and the repository save
            // overwrites the whole document, so these must be carried over or they're erased.
            home.photoURLs = existing.photoURLs
            // The merged public calendar; the form doesn't touch its private halves,
            // but dropping the union would reopen every closed day until the next rewrite.
            home.unavailableDateRanges = existing.unavailableDateRanges

            // A co-host is editing: fields the rules pin to the host are carried over
            // from the stored listing, else `hostName` would become the co-host's and
            // `allowedViewerIDs` would republish the listing to the co-host's friends.
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

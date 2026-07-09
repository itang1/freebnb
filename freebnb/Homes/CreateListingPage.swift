//
//  CreateListingPage.swift
//  freebnb
//

import CoreLocation
import Observation
import SwiftUI

// MARK: - View model

@Observable
final class CreateListingViewModel {
    // When non-nil, the form edits this listing instead of creating a new one.
    let editing: Home?

    // Location
    var street: String
    var city: String
    var stateField: String
    var zip: String

    // Capacity
    var numGuestRooms: Int
    var maxGuests: Int
    var maxStayDays: Int
    var sleepingCounts: [SleepingSurface: Int]
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

    // Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    var foodProvision: FoodProvision

    // Host and contact
    var description: String
    var contactPreference: HostContactPreference
    var hostContactInfo: String
    var hostMotivation: HostMotivation
    var cancellationPolicy: CancellationPolicy
    var visibility: ListingVisibility

    // Save state
    var isSaving = false
    var errorMessage: String?
    // Set when geocoding the address returned nothing. The listing is still
    // saveable without a map pin, but the host is told rather than left to
    // wonder why their listing never shows on the map (L6).
    var geocodeFailed = false

    init(editing: Home? = nil) {
        self.editing = editing
        // The street is not on the public listing document; when editing it has to
        // be loaded from the private location subdoc (see `loadStreet`). Until it
        // arrives `canSave` is false, so an edit can never blank out the address.
        street = ""
        city = editing?.address.city ?? ""
        stateField = editing?.address.state ?? ""
        zip = editing?.address.zip ?? ""
        numGuestRooms = editing?.sleeping.numGuestRooms ?? 1
        maxGuests = editing?.guestPolicy.maxGuests ?? 2
        maxStayDays = editing?.guestPolicy.maxStayDays ?? 7
        sleepingCounts = editing?.sleeping.sleepingCounts ?? [:]
        kidsAllowed = editing?.guestPolicy.kidsAllowed ?? true
        guestPetsAllowed = editing?.guestPolicy.guestPetsAllowed ?? false
        hostHasPets = editing?.amenities.hostHasPets ?? false
        hasAC = editing?.amenities.hasAC ?? false
        hasHeating = editing?.amenities.hasHeating ?? false
        hasKitchen = editing?.amenities.hasKitchen ?? false
        hasFridgeSpace = editing?.amenities.hasFridgeSpace ?? false
        hasMicrowave = editing?.amenities.hasMicrowave ?? false
        hasTV = editing?.amenities.hasTV ?? false
        hasWifi = editing?.amenities.hasWifi ?? false
        hasPrivateGuestBathroom = editing?.amenities.hasPrivateGuestBathroom ?? false
        parkingDetails = editing?.amenities.parkingDetails ?? ""
        hasInUnitLaundry = editing?.amenities.hasInUnitLaundry ?? false
        hasCoinLaundryNearby = editing?.amenities.hasCoinLaundryNearby ?? false
        providesPillows = editing?.amenities.providesPillows ?? false
        providesBlankets = editing?.amenities.providesBlankets ?? false
        providesTowels = editing?.amenities.providesTowels ?? false
        providesToiletries = editing?.amenities.providesToiletries ?? false
        foodProvision = editing?.amenities.foodProvision ?? .none
        description = editing?.description ?? ""
        contactPreference = editing?.contactPreference ?? .inApp
        hostContactInfo = editing?.hostContactInfo ?? ""
        hostMotivation = editing?.hostMotivation ?? .open
        cancellationPolicy = editing?.cancellationPolicy ?? .flexible
        visibility = editing?.visibility ?? .everyone
    }

    /// Pulls the street address of the listing being edited out of its private
    /// location document. A host always has read access to their own.
    func loadStreet(homeStore: HomeStore) async {
        guard let editing, street.isEmpty else { return }
        street = await homeStore.location(for: editing.id)?.street ?? ""
    }

    func canSave(displayName: String) -> Bool {
        guard !isSaving else { return false }
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
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

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactInfo = hostContactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStreet = street.trimmingCharacters(in: .whitespaces)
        let sleepingRaw = sleepingCounts.reduce(into: [String: Int]()) { acc, pair in
            acc[pair.key.rawValue] = pair.value
        }

        var home = Home(
            hostUserID: hostUserID,
            hostName: hostName,
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
                arrangements: sleepingRaw
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
                foodProvision: foodProvision
            ),
            cancellationPolicy: cancellationPolicy
        )
        home.visibility = visibility
        // Recomputed on every save rather than carried over from `editing`, so an
        // edit picks up friends added since the listing was created. The
        // `onFriendEdgeWritten` function keeps it current between saves.
        home.allowedViewerIDs = Home.viewerIDs(hostUserID: hostUserID, friendIDs: friendIDs)
        // Preserve identity and creation time when editing so an edit keeps the
        // listing's feed position instead of jumping to the top (L3).
        if let existing = editing {
            home.id = existing.id
            home.createdAt = existing.createdAt
        }

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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - View

struct CreateListingPage: View {
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(\.dismiss) private var dismiss

    @State private var vm: CreateListingViewModel

    init(editing: Home? = nil) {
        _vm = State(initialValue: CreateListingViewModel(editing: editing))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let missingNameMessage {
                    Section {
                        Label(missingNameMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }

                locationSection
                capacitySection
                sleepingSection
                guestsAndPetsSection
                amenitiesSection
                roomsAndLaundrySection
                provisionsSection
                contactSection
                motivationSection
                cancellationPolicySection
                visibilitySection
                descriptionSection

                if vm.geocodeFailed {
                    Section {
                        Label("We couldn't place that address on the map. Fix it and tap Save to retry, or save without a map location.", systemImage: "mappin.slash")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                        Button("Save without map location") {
                            Task { if await saveListing(allowMissingCoordinates: true) { dismiss() } }
                        }
                    }
                }

                if let errorMessage = vm.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(vm.editing == nil ? "New Listing" : "Edit Listing")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(vm.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await saveListing() { dismiss() } }
                    }
                    .disabled(!vm.canSave(displayName: userProfileStore.displayName ?? ""))
                }
            }
            .disabled(vm.isSaving)
            .task { await vm.loadStreet(homeStore: homeStore) }
        }
    }

    // MARK: - Actions

    /// Bridges the toolbar and the "save without map location" button to the
    /// view model. Returns `true` when the sheet should dismiss.
    private func saveListing(allowMissingCoordinates: Bool = false) async -> Bool {
        await vm.save(
            homeStore: homeStore,
            hostUserID: authManager.userID,
            hostName: userProfileStore.displayName ?? "",
            friendIDs: friendStore.friendIDs,
            allowMissingCoordinates: allowMissingCoordinates
        )
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section("Location") {
            AddressSearchField(
                street: $vm.street,
                city: $vm.city,
                state: $vm.stateField,
                zip: $vm.zip
            )
        }
    }

    private var capacitySection: some View {
        Section("Capacity") {
            Stepper("Guest rooms: \(vm.numGuestRooms)", value: $vm.numGuestRooms, in: 0...10)
            Stepper("Max guests: \(vm.maxGuests)", value: $vm.maxGuests, in: 1...20)
            Stepper("Max stay: \(vm.maxStayDays) night\(vm.maxStayDays == 1 ? "" : "s")", value: $vm.maxStayDays, in: 1...365)
        }
    }

    private var sleepingSection: some View {
        Section("Sleeping arrangements") {
            ForEach(SleepingSurface.allCases, id: \.self) { surface in
                Stepper(
                    "\(vm.sleepingCounts[surface, default: 0]) \(surface.displayName)\(vm.sleepingCounts[surface, default: 0] == 1 ? "" : "s")",
                    value: Binding(
                        get: { vm.sleepingCounts[surface, default: 0] },
                        set: { newValue in
                            if newValue <= 0 { vm.sleepingCounts.removeValue(forKey: surface) }
                            else { vm.sleepingCounts[surface] = newValue }
                        }
                    ),
                    in: 0...20
                )
            }
            if vm.sleepingCounts.isEmpty {
                Text("Add at least one sleeping surface so guests know where they'll sleep.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var guestsAndPetsSection: some View {
        Section("Guests and pets") {
            Toggle("Kids allowed", isOn: $vm.kidsAllowed)
            Toggle("Guest can bring pets", isOn: $vm.guestPetsAllowed)
            Toggle("Host has pets", isOn: $vm.hostHasPets)
        }
    }

    private var amenitiesSection: some View {
        Section("Amenities") {
            Toggle("Air conditioning", isOn: $vm.hasAC)
            Toggle("Heating", isOn: $vm.hasHeating)
            Toggle("Kitchen", isOn: $vm.hasKitchen)
            Toggle("Fridge space for guest", isOn: $vm.hasFridgeSpace)
            Toggle("Microwave", isOn: $vm.hasMicrowave)
            Toggle("TV", isOn: $vm.hasTV)
            Toggle("Wifi", isOn: $vm.hasWifi)
        }
    }

    private var roomsAndLaundrySection: some View {
        Section("Rooms and laundry") {
            Toggle("Private guest bathroom", isOn: $vm.hasPrivateGuestBathroom)
            Toggle("In-unit laundry", isOn: $vm.hasInUnitLaundry)
            Toggle("Coin laundry nearby", isOn: $vm.hasCoinLaundryNearby)
            TextField("Parking details (optional)", text: $vm.parkingDetails, axis: .vertical)
                .lineLimit(1...3)
        }
    }

    private var provisionsSection: some View {
        Section("Provisions") {
            Toggle("Pillows", isOn: $vm.providesPillows)
            Toggle("Blankets", isOn: $vm.providesBlankets)
            Toggle("Towels", isOn: $vm.providesTowels)
            Toggle("Toiletries", isOn: $vm.providesToiletries)
            Picker("Food", selection: $vm.foodProvision) {
                ForEach(FoodProvision.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
    }

    private var contactSection: some View {
        Section("How guests reach you") {
            Picker("Preference", selection: $vm.contactPreference) {
                Text("In-app messaging").tag(HostContactPreference.inApp)
                Text("Share contact info").tag(HostContactPreference.contactInfo)
            }
            if vm.contactPreference == .contactInfo {
                TextField("Phone, email, or handle", text: $vm.hostContactInfo)
                    .textContentType(.emailAddress)
            }
        }
    }

    private var motivationSection: some View {
        Section("How eager are you to host?") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(HostMotivation.allCases, id: \.self) { motivation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.hostMotivation == motivation ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(vm.hostMotivation == motivation ? .accent : .secondary.opacity(0.5))
                            Text(motivation.displayName)
                                .font(.body)
                        }
                        Text(motivation.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.hostMotivation = motivation }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var cancellationPolicySection: some View {
        Section("Cancellation policy") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(CancellationPolicy.allCases, id: \.self) { policy in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.cancellationPolicy == policy ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(vm.cancellationPolicy == policy ? .accent : .secondary.opacity(0.5))
                            Text(policy.displayName)
                                .font(.body)
                        }
                        Text(policy.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.cancellationPolicy = policy }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var visibilitySection: some View {
        Section("Who can see this listing") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ListingVisibility.allCases, id: \.self) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.visibility == option ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(vm.visibility == option ? .accent : .secondary.opacity(0.5))
                            Text(option.displayName)
                                .font(.body)
                        }
                        Text(option.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.visibility = option }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var descriptionSection: some View {
        Section("Memo (optional)") {
            TextField("Anything guests should know", text: $vm.description, axis: .vertical)
                .lineLimit(2...8)
            if !vm.description.isEmpty {
                Text("\(vm.description.count) characters")
                    .font(.caption)
                    .foregroundColor(vm.description.count > 500 ? .orange : .secondary)
            }
        }
    }

    // MARK: - Derived state

    private var missingNameMessage: String? {
        guard (userProfileStore.displayName ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "Add your name on your profile before creating a listing."
    }
}

#Preview {
    CreateListingPage()
        .environment(HomeStore())
        .environment(AuthManager())
        .environment(UserProfileStore())
        .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
}

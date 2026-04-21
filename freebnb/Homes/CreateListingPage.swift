//
//  CreateListingPage.swift
//  freebnb
//

import SwiftUI

struct CreateListingPage: View {
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    // When non-nil, the form edits this listing instead of creating a new one.
    private let editing: Home?

    // Location
    @State private var street: String
    @State private var city: String
    @State private var stateField: String
    @State private var zip: String

    // Capacity
    @State private var numGuestRooms: Int
    @State private var maxGuests: Int
    @State private var maxStayDays: Int
    @State private var sleepingCounts: [SleepingSurface: Int]
    @State private var kidsAllowed: Bool
    @State private var guestPetsAllowed: Bool
    @State private var hostHasPets: Bool

    // Amenities
    @State private var hasAC: Bool
    @State private var hasHeating: Bool
    @State private var hasKitchen: Bool
    @State private var hasFridgeSpace: Bool
    @State private var hasMicrowave: Bool
    @State private var hasTV: Bool
    @State private var hasWifi: Bool

    // Rooms and laundry
    @State private var hasPrivateGuestBathroom: Bool
    @State private var parkingDetails: String
    @State private var hasInUnitLaundry: Bool
    @State private var hasCoinLaundryNearby: Bool

    // Provisions
    @State private var providesPillows: Bool
    @State private var providesBlankets: Bool
    @State private var providesTowels: Bool
    @State private var providesToiletries: Bool
    @State private var foodProvision: FoodProvision

    // Host and contact
    @State private var description: String
    @State private var contactPreference: HostContactPreference
    @State private var hostContactInfo: String
    @State private var hostMotivation: HostMotivation

    // State
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(editing: Home? = nil) {
        self.editing = editing
        _street = State(initialValue: editing?.address.street ?? "")
        _city = State(initialValue: editing?.address.city ?? "")
        _stateField = State(initialValue: editing?.address.state ?? "")
        _zip = State(initialValue: editing?.address.zip ?? "")
        _numGuestRooms = State(initialValue: editing?.numGuestRooms ?? 1)
        _maxGuests = State(initialValue: editing?.maxGuests ?? 2)
        _maxStayDays = State(initialValue: editing?.maxStayDays ?? 7)
        _sleepingCounts = State(initialValue: editing?.sleepingCounts ?? [:])
        _kidsAllowed = State(initialValue: editing?.kidsAllowed ?? true)
        _guestPetsAllowed = State(initialValue: editing?.guestPetsAllowed ?? false)
        _hostHasPets = State(initialValue: editing?.hostHasPets ?? false)
        _hasAC = State(initialValue: editing?.hasAC ?? false)
        _hasHeating = State(initialValue: editing?.hasHeating ?? false)
        _hasKitchen = State(initialValue: editing?.hasKitchen ?? false)
        _hasFridgeSpace = State(initialValue: editing?.hasFridgeSpace ?? false)
        _hasMicrowave = State(initialValue: editing?.hasMicrowave ?? false)
        _hasTV = State(initialValue: editing?.hasTV ?? false)
        _hasWifi = State(initialValue: editing?.hasWifi ?? false)
        _hasPrivateGuestBathroom = State(initialValue: editing?.hasPrivateGuestBathroom ?? false)
        _parkingDetails = State(initialValue: editing?.parkingDetails ?? "")
        _hasInUnitLaundry = State(initialValue: editing?.hasInUnitLaundry ?? false)
        _hasCoinLaundryNearby = State(initialValue: editing?.hasCoinLaundryNearby ?? false)
        _providesPillows = State(initialValue: editing?.providesPillows ?? false)
        _providesBlankets = State(initialValue: editing?.providesBlankets ?? false)
        _providesTowels = State(initialValue: editing?.providesTowels ?? false)
        _providesToiletries = State(initialValue: editing?.providesToiletries ?? false)
        _foodProvision = State(initialValue: editing?.foodProvision ?? .none)
        _description = State(initialValue: editing?.description ?? "")
        _contactPreference = State(initialValue: editing?.contactPreference ?? .inApp)
        _hostContactInfo = State(initialValue: editing?.hostContactInfo ?? "")
        _hostMotivation = State(initialValue: editing?.hostMotivation ?? .open)
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
                descriptionSection

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Listing" : "Edit Listing")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .disabled(isSaving)
        }
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section("Location") {
            TextField("Street", text: $street)
                .textContentType(.streetAddressLine1)
            TextField("City", text: $city)
                .textContentType(.addressCity)
            TextField("State", text: $stateField)
                .textContentType(.addressState)
            TextField("ZIP", text: $zip)
                .textContentType(.postalCode)
                #if !os(macOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    private var capacitySection: some View {
        Section("Capacity") {
            Stepper("Guest rooms: \(numGuestRooms)", value: $numGuestRooms, in: 0...10)
            Stepper("Max guests: \(maxGuests)", value: $maxGuests, in: 1...20)
            Stepper("Max stay: \(maxStayDays) night\(maxStayDays == 1 ? "" : "s")", value: $maxStayDays, in: 1...365)
        }
    }

    private var sleepingSection: some View {
        Section("Sleeping arrangements") {
            ForEach(SleepingSurface.allCases, id: \.self) { surface in
                Stepper(
                    "\(sleepingCounts[surface, default: 0]) \(surface.displayName)\(sleepingCounts[surface, default: 0] == 1 ? "" : "s")",
                    value: Binding(
                        get: { sleepingCounts[surface, default: 0] },
                        set: { newValue in
                            if newValue <= 0 { sleepingCounts.removeValue(forKey: surface) }
                            else { sleepingCounts[surface] = newValue }
                        }
                    ),
                    in: 0...20
                )
            }
            if sleepingCounts.isEmpty {
                Text("Add at least one sleeping surface so guests know where they'll sleep.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var guestsAndPetsSection: some View {
        Section("Guests and pets") {
            Toggle("Kids allowed", isOn: $kidsAllowed)
            Toggle("Guest can bring pets", isOn: $guestPetsAllowed)
            Toggle("Host has pets", isOn: $hostHasPets)
        }
    }

    private var amenitiesSection: some View {
        Section("Amenities") {
            Toggle("Air conditioning", isOn: $hasAC)
            Toggle("Heating", isOn: $hasHeating)
            Toggle("Kitchen", isOn: $hasKitchen)
            Toggle("Fridge space for guest", isOn: $hasFridgeSpace)
            Toggle("Microwave", isOn: $hasMicrowave)
            Toggle("TV", isOn: $hasTV)
            Toggle("Wifi", isOn: $hasWifi)
        }
    }

    private var roomsAndLaundrySection: some View {
        Section("Rooms and laundry") {
            Toggle("Private guest bathroom", isOn: $hasPrivateGuestBathroom)
            Toggle("In-unit laundry", isOn: $hasInUnitLaundry)
            Toggle("Coin laundry nearby", isOn: $hasCoinLaundryNearby)
            TextField("Parking details (optional)", text: $parkingDetails, axis: .vertical)
                .lineLimit(1...3)
        }
    }

    private var provisionsSection: some View {
        Section("Provisions") {
            Toggle("Pillows", isOn: $providesPillows)
            Toggle("Blankets", isOn: $providesBlankets)
            Toggle("Towels", isOn: $providesTowels)
            Toggle("Toiletries", isOn: $providesToiletries)
            Picker("Food", selection: $foodProvision) {
                ForEach(FoodProvision.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
    }

    private var contactSection: some View {
        Section("How guests reach you") {
            Picker("Preference", selection: $contactPreference) {
                Text("In-app messaging").tag(HostContactPreference.inApp)
                Text("Share contact info").tag(HostContactPreference.contactInfo)
            }
            if contactPreference == .contactInfo {
                TextField("Phone, email, or handle", text: $hostContactInfo)
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
                            Image(systemName: hostMotivation == motivation ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(hostMotivation == motivation ? .appTeal : .secondary.opacity(0.5))
                            Text(motivation.displayName)
                                .font(.body)
                        }
                        Text(motivation.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { hostMotivation = motivation }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var descriptionSection: some View {
        Section("Memo (optional)") {
            TextField("Anything guests should know", text: $description, axis: .vertical)
                .lineLimit(2...8)
        }
    }

    // MARK: - Derived state

    private var missingNameMessage: String? {
        guard userProfileStore.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "Add your name on your profile before creating a listing."
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        guard missingNameMessage == nil else { return false }
        guard !street.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !city.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !stateField.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !zip.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !sleepingCounts.isEmpty else { return false }
        if contactPreference == .contactInfo,
           hostContactInfo.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactInfo = hostContactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepingRaw = sleepingCounts.reduce(into: [String: Int]()) { acc, pair in
            acc[pair.key.rawValue] = pair.value
        }

        var home = Home(
            hostUserID: authManager.userID,
            hostName: userProfileStore.displayName,
            address: Address(
                street: street.trimmingCharacters(in: .whitespaces),
                city: city.trimmingCharacters(in: .whitespaces),
                state: stateField.trimmingCharacters(in: .whitespaces),
                zip: zip.trimmingCharacters(in: .whitespaces)
            ),
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            contactPreference: contactPreference,
            hostContactInfo: contactPreference == .contactInfo && !trimmedContactInfo.isEmpty ? trimmedContactInfo : nil,
            hostMotivation: hostMotivation,
            numGuestRooms: numGuestRooms,
            maxGuests: maxGuests,
            maxStayDays: maxStayDays,
            sleepingArrangements: sleepingRaw,
            kidsAllowed: kidsAllowed,
            guestPetsAllowed: guestPetsAllowed,
            hostHasPets: hostHasPets,
            hasAC: hasAC,
            hasHeating: hasHeating,
            hasKitchen: hasKitchen,
            hasFridgeSpace: hasFridgeSpace,
            hasMicrowave: hasMicrowave,
            hasTV: hasTV,
            hasWifi: hasWifi,
            hasPrivateGuestBathroom: hasPrivateGuestBathroom,
            parkingDetails: parkingDetails.trimmingCharacters(in: .whitespacesAndNewlines),
            hasInUnitLaundry: hasInUnitLaundry,
            hasCoinLaundryNearby: hasCoinLaundryNearby,
            providesPillows: providesPillows,
            providesBlankets: providesBlankets,
            providesTowels: providesTowels,
            providesToiletries: providesToiletries,
            foodProvision: foodProvision
        )
        // Preserve the listing id when editing
        if let existing = editing { home.id = existing.id }

        do {
            try await homeStore.save(home)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    CreateListingPage()
        .environment(HomeStore())
        .environment(AuthManager())
        .environment(UserProfileStore())
}

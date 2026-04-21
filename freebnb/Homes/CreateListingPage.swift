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

    // Location
    @State private var street = ""
    @State private var city = ""
    @State private var stateField = ""
    @State private var zip = ""

    // Capacity
    @State private var numGuestRooms = 1
    @State private var maxGuests = 2
    @State private var maxStayDays = 7
    @State private var sleepingCounts: [SleepingSurface: Int] = [:]
    @State private var kidsAllowed = true
    @State private var guestPetsAllowed = false
    @State private var hostHasPets = false

    // Amenities
    @State private var hasAC = false
    @State private var hasHeating = false
    @State private var hasKitchen = false
    @State private var hasFridgeSpace = false
    @State private var hasMicrowave = false
    @State private var hasTV = false
    @State private var hasWifi = false

    // Rooms and laundry
    @State private var hasPrivateGuestBathroom = false
    @State private var parkingDetails = ""
    @State private var hasInUnitLaundry = false
    @State private var hasCoinLaundryNearby = false

    // Provisions
    @State private var providesPillows = false
    @State private var providesBlankets = false
    @State private var providesTowels = false
    @State private var providesToiletries = false
    @State private var foodProvision: FoodProvision = .none

    // Host and contact
    @State private var description = ""
    @State private var contactPreference: HostContactPreference = .inApp
    @State private var hostContactInfo = ""

    // State
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                descriptionSection

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Listing")
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

        let home = Home(
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

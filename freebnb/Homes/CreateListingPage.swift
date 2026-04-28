//
//  CreateListingPage.swift
//  freebnb
//

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

    // Save state
    var isSaving = false
    var errorMessage: String?

    init(editing: Home? = nil) {
        self.editing = editing
        street = editing?.address.street ?? ""
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

    func save(homeStore: HomeStore, hostUserID: String, hostName: String) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContactInfo = hostContactInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepingRaw = sleepingCounts.reduce(into: [String: Int]()) { acc, pair in
            acc[pair.key.rawValue] = pair.value
        }

        var home = Home(
            hostUserID: hostUserID,
            hostName: hostName,
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
        // Preserve the listing id when editing
        if let existing = editing { home.id = existing.id }

        do {
            try await homeStore.save(home)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - View

struct CreateListingPage: View {
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
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
                descriptionSection

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
                        Task {
                            await vm.save(
                                homeStore: homeStore,
                                hostUserID: authManager.userID,
                                hostName: userProfileStore.displayName ?? ""
                            )
                            if vm.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!vm.canSave(displayName: userProfileStore.displayName ?? ""))
                }
            }
            .disabled(vm.isSaving)
        }
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
                                .foregroundColor(vm.hostMotivation == motivation ? .appTeal : .secondary.opacity(0.5))
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
                                .foregroundColor(vm.cancellationPolicy == policy ? .appTeal : .secondary.opacity(0.5))
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

    private var descriptionSection: some View {
        Section("Memo (optional)") {
            TextField("Anything guests should know", text: $vm.description, axis: .vertical)
                .lineLimit(2...8)
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
}

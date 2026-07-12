//
//  CreateListingPage.swift
//  freebnb
//

import SwiftUI

// MARK: - View

struct CreateListingPage: View {
    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(\.dismiss) private var dismiss

    @State private var vm: CreateListingViewModel

    private let draftStore = ListingDraftStore()

    init(mode: ListingFormMode = .create) {
        _vm = State(initialValue: CreateListingViewModel(mode: mode))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let missingNameMessage {
                    Section { InlineErrorLabel(message: missingNameMessage, tint: .orange) }
                }

                if vm.restoredDraft {
                    Section {
                        Label("We kept the listing you started. Pick up where you left off.", systemImage: "arrow.uturn.backward.circle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Start over", role: .destructive) {
                            vm.discardDraft(from: draftStore, userID: authManager.userID)
                        }
                    }
                }

                locationSection
                capacitySection
                sleepingSection
                bedSizesSection
                guestsAndPetsSection
                accessibilitySection
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
                    Section { InlineErrorLabel(message: errorMessage) }
                }
            }
            .navigationTitle(vm.mode.navigationTitle)
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
            .task {
                // Before loadStreet, which no-ops on a street the draft restored.
                vm.restoreDraft(from: draftStore, userID: authManager.userID)
                await vm.loadStreet(homeStore: homeStore)
            }
            // Autosave rather than prompting on Cancel: the sheet can also leave by
            // a swipe down, which no confirmation dialog gets to intercept.
            .onChange(of: vm.draft) { _, _ in
                vm.persistDraft(to: draftStore, userID: authManager.userID)
            }
        }
    }

    // MARK: - Actions

    /// Bridges the toolbar and the "save without map location" button to the
    /// view model. Returns `true` when the sheet should dismiss.
    ///
    /// The draft is cleared only on a save that actually landed. A geocode failure
    /// or a rejected write leaves the sheet open with the draft intact behind it.
    private func saveListing(allowMissingCoordinates: Bool = false) async -> Bool {
        let saved = await vm.save(
            homeStore: homeStore,
            hostUserID: authManager.userID,
            hostName: userProfileStore.displayName ?? "",
            friendIDs: friendStore.friendIDs,
            allowMissingCoordinates: allowMissingCoordinates
        )
        if saved {
            draftStore.clear(userID: authManager.userID)
        }
        return saved
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
            Stepper(
                vm.numBathrooms == 0
                    ? "Bathrooms: not specified"
                    : "Bathrooms: \(vm.numBathrooms)",
                value: $vm.numBathrooms,
                in: 0...10
            )
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

    /// Only shown once the listing has a bed, since a couch has no size worth
    /// naming. The save drops these if the last bed goes away.
    @ViewBuilder
    private var bedSizesSection: some View {
        if (vm.sleepingCounts[.bed] ?? 0) > 0 {
            Section("Bed sizes (optional)") {
                ForEach(BedSize.allCases.sorted { $0.rank < $1.rank }, id: \.self) { size in
                    Stepper(
                        "\(vm.bedSizeCounts[size, default: 0]) \(size.displayName)",
                        value: Binding(
                            get: { vm.bedSizeCounts[size, default: 0] },
                            set: { newValue in
                                if newValue <= 0 { vm.bedSizeCounts.removeValue(forKey: size) }
                                else { vm.bedSizeCounts[size] = newValue }
                            }
                        ),
                        in: 0...20
                    )
                }
                Text("Guests filtering for a queen or king won't see listings that leave this blank.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accessibilitySection: some View {
        Section("Accessibility") {
            Toggle("Step-free entry", isOn: $vm.hasStepFreeEntry)
            Toggle("Elevator", isOn: $vm.hasElevator)
            Toggle("Accessible bathroom", isOn: $vm.hasAccessibleBathroom)
            Text("Only turn these on if you're confident. A guest may be relying on them to get through the door.")
                .font(.caption)
                .foregroundColor(.secondary)
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
        ChoiceSection(
            title: "How eager are you to host?",
            options: HostMotivation.allCases,
            selection: $vm.hostMotivation,
            name: { $0.displayName },
            detail: { $0.description }
        )
    }

    private var cancellationPolicySection: some View {
        ChoiceSection(
            title: "Cancellation policy",
            options: CancellationPolicy.allCases,
            selection: $vm.cancellationPolicy,
            name: { $0.displayName },
            detail: { $0.description }
        )
    }

    // Not a setting: every listing is friends-only by design. Stated here so a
    // host never has to wonder who is about to see their home.
    private var visibilitySection: some View {
        Section("Who can see this listing") {
            Label {
                Text("Only your FreeBNB friends can see and request to book this listing. It is never public.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
            }
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
        .previewEnvironment()
}

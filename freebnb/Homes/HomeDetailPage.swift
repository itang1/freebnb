//
//  HomeDetailPage.swift
//  freebnb
//

import SwiftUI
import MapKit

struct HomeDetailPage: View {
    let home: Home

    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @State private var region = MKCoordinateRegion()
    @State private var mapItems: [MKMapItem] = []
    @State private var mapState: MapState = .loading
    @State private var geocodeTask: Task<Void, Never>?
    @State private var showReport = false
    @State private var showBlockConfirm = false
    // Bridge @Observable → @State so the toolbar re-renders reliably.
    @State private var isListingSaved = false
    @State private var saveError: String?

    private enum MapState: Equatable {
        case loading
        case loaded
        case failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: Host motivation + trust signals
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: home.hostMotivation.iconName)
                            .font(.caption2)
                        Text(home.hostMotivation.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(home.hostMotivation.tintColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(home.hostMotivation.tintColor.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel("Host motivation: \(home.hostMotivation.displayName)")

                    hostTrustSignals
                }

                // MARK: Details
                Text("Details")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest Rooms: \(home.sleeping.numGuestRooms)")
                    Text("Max Guests: \(home.guestPolicy.maxGuests)")
                    Text("Max Stay: \(home.guestPolicy.maxStayDays) night\(home.guestPolicy.maxStayDays == 1 ? "" : "s")")
                    if !home.sleeping.sleepingCounts.isEmpty {
                        Text("Sleeping Arrangements: \(home.sleeping.arrangementsDescription)")
                    }
                }
                .font(.subheadline)

                // MARK: Guests & Space
                Text("Guests & Space")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Kids Allowed", available: home.guestPolicy.kidsAllowed)
                    amenityRow("Guest Can Bring Pets", available: home.guestPolicy.guestPetsAllowed)
                    amenityRow("Host Has Pets", available: home.amenities.hostHasPets)
                }
                .font(.subheadline)

                // MARK: Amenities
                Text("Amenities")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Air Conditioning", available: home.amenities.hasAC)
                    amenityRow("Heating", available: home.amenities.hasHeating)
                    amenityRow("Kitchen", available: home.amenities.hasKitchen)
                    amenityRow("Fridge Space", available: home.amenities.hasFridgeSpace)
                    amenityRow("Microwave", available: home.amenities.hasMicrowave)
                    amenityRow("TV", available: home.amenities.hasTV)
                    amenityRow("Wifi", available: home.amenities.hasWifi)
                }
                .font(.subheadline)

                // MARK: Rooms & Laundry
                Text("Rooms & Laundry")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Private Guest Bathroom", available: home.amenities.hasPrivateGuestBathroom)
                    amenityRow("In-unit Laundry", available: home.amenities.hasInUnitLaundry)
                    amenityRow("Coin Laundry Nearby", available: home.amenities.hasCoinLaundryNearby)
                }
                .font(.subheadline)

                // MARK: Parking
                if !home.amenities.parkingDetails.isEmpty {
                    Text("Parking")
                        .font(.headline)
                    Text(home.amenities.parkingDetails)
                        .font(.subheadline)
                }

                // MARK: Provisions
                Text("Provisions")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Pillows", available: home.amenities.providesPillows)
                    amenityRow("Blankets", available: home.amenities.providesBlankets)
                    amenityRow("Towels", available: home.amenities.providesTowels)
                    amenityRow("Toiletries", available: home.amenities.providesToiletries)
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .foregroundColor(home.amenities.foodProvision == .none ? .secondary.opacity(0.75) : .green)
                            .accessibilityHidden(true)
                        Text("Food: \(home.amenities.foodProvision.displayName)")
                            .foregroundColor(home.amenities.foodProvision == .none ? .secondary.opacity(0.75) : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .font(.subheadline)

                // MARK: Cancellation Policy
                let policy = home.cancellationPolicy ?? .flexible
                Spacer(minLength: 10)
                Text("Cancellation Policy")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(policy.displayName)
                        .font(.subheadline).fontWeight(.medium)
                    Text(policy.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let description = home.description, !description.isEmpty {
                    Spacer(minLength: 10)
                    Text("Memo")
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                }

                Spacer(minLength: 10)

                if authManager.userID != home.hostUserID {
                    Text("Contact Host")
                        .font(.headline)
                    contactSection
                }

                Spacer(minLength: 10)

                Text("View on Map")
                    .font(.headline)

                Text(formattedAddress)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                mapSection

                Button(action: openInMaps) {
                    Text("Open in Apple Maps")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.coral)
                        .foregroundColor(.onBrandFill)
                        .cornerRadius(10)
                }
                .disabled(mapState != .loaded)

                if authManager.userID != home.hostUserID {
                    Divider().padding(.vertical, 8)
                    HStack(spacing: 24) {
                        Button {
                            showReport = true
                        } label: {
                            Label("Report listing", systemImage: "flag")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showBlockConfirm = true
                        } label: {
                            let blocked = userProfileStore.isBlocked(home.hostUserID)
                            Label(blocked ? "Unblock \(home.hostName)" : "Block \(home.hostName)",
                                  systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .onAppear {
            startGeocoding()
            isListingSaved = userProfileStore.isSaved(home.id)
        }
        .onChange(of: userProfileStore.currentProfile?.savedListingIDs) { _, _ in
            isListingSaved = userProfileStore.isSaved(home.id)
        }
        .onDisappear {
            geocodeTask?.cancel()
            geocodeTask = nil
        }
        .navigationTitle(home.hostName)
        .toolbar {
            if authManager.authMethod != .guest {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let newValue = !isListingSaved
                        isListingSaved = newValue          // optimistic
                        Task {
                            do {
                                try await userProfileStore.toggleSavedListing(home.id)
                            } catch {
                                isListingSaved = !newValue // revert
                                saveError = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: isListingSaved ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(Color.appTeal)
                    }
                    .accessibilityLabel(isListingSaved ? "Remove from saved" : "Save listing")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: "\(home.hostName) is hosting in \(home.address.city), \(home.address.state) on FreeBNB. Ask them for an invite!",
                    subject: Text("FreeBNB Listing")
                )
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: .listing, targetID: home.id, targetName: "\(home.hostName)'s listing in \(home.address.city)")
        }
        .confirmationDialog(
            userProfileStore.isBlocked(home.hostUserID)
                ? "Unblock \(home.hostName)?"
                : "Block \(home.hostName)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            if userProfileStore.isBlocked(home.hostUserID) {
                Button("Unblock") { Task { try? await userProfileStore.unblockUser(home.hostUserID) } }
            } else {
                Button("Block", role: .destructive) { Task { try? await userProfileStore.blockUser(home.hostUserID) } }
            }
        } message: {
            if userProfileStore.isBlocked(home.hostUserID) {
                Text("You will see their listings again.")
            } else {
                Text("Their listings won't appear and they won't be able to message you.")
            }
        }
        .background(Color.creamWhite)
        .alert("Couldn't save listing", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let saveError { Text(saveError) }
        }
    }

    // MARK: - Trust signals

    @ViewBuilder
    private var hostTrustSignals: some View {
        Label("Verified name", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundColor(Color.appTeal)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.appTeal.opacity(0.1))
            .clipShape(Capsule())

        if let profile = userProfileStore.profile(for: home.hostUserID),
           let createdAt = profile.createdAt {
            let year = Calendar.current.component(.year, from: createdAt)
            Label("Since \(year)", systemImage: "calendar")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
    }

    // MARK: - Map section

    @ViewBuilder
    private var mapSection: some View {
        Group {
            switch mapState {
            case .loading:
                SkeletonMapBlock()
            case .loaded:
                Map(initialPosition: .region(region)) {
                    ForEach(mapItems, id: \.self) { item in
                        Marker(item.name ?? "Location", coordinate: item.placemark.coordinate)
                    }
                }
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "location.slash")
                        .foregroundColor(.secondary)
                    Text("Map unavailable — address shown above")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .crossFades(on: mapState)
    }

    // MARK: - Geocoding

    private func startGeocoding() {
        guard mapState == .loading else { return }
        let hostName = home.hostName

        // Listings save their geocoded coordinates at creation time. Reuse them
        // and skip the network geocode entirely; only fall back to geocoding the
        // address string for legacy listings saved before coordinates existed.
        if let latitude = home.latitude, let longitude = home.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = hostName
            mapItems = [item]
            region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            mapState = .loaded
            return
        }

        let address = formattedAddress
        geocodeTask?.cancel()
        geocodeTask = Task {
            do {
                let coordinate = try await GeocodingCache.shared.coordinate(for: address)
                guard !Task.isCancelled else { return }
                let placemark = MKPlacemark(coordinate: coordinate)
                let item = MKMapItem(placemark: placemark)
                item.name = hostName
                mapItems = [item]
                region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
                mapState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                mapState = .failed
            }
        }
    }

    private var formattedAddress: String {
        "\(home.address.street), \(home.address.city), \(home.address.state) \(home.address.zip)"
    }

    // MARK: - Contact section

    @ViewBuilder
    private var contactSection: some View {
        switch home.contactPreference {
        case .inApp:
            if authManager.authMethod == .guest {
                Text("Create a free account to message \(home.hostName) and request a stay.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                let existing = requestStore.activeRequest(for: home.id, guestUserID: authManager.userID)
                VStack(spacing: 10) {
                    if let existing {
                        existingRequestBanner(existing)
                    }
                    NavigationLink {
                        MessagingPage(
                            otherUserID: home.hostUserID,
                            otherName: home.hostName,
                            listing: home
                        )
                    } label: {
                        Label(
                            existing == nil ? "Message \(home.hostName)" : "Open conversation",
                            systemImage: "message.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.appTeal)
                        .foregroundColor(.onBrandFill)
                        .cornerRadius(10)
                    }
                }
            }
        case .contactInfo:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(home.hostName) prefers to be contacted directly:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let info = home.hostContactInfo, !info.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .foregroundColor(Color.appTeal)
                        Text(info)
                            .font(.subheadline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Existing request banner

    private func existingRequestBanner(_ request: StayRequest) -> some View {
        let f = AppDateFormatters.mediumDate
        return HStack(spacing: 10) {
            Image(systemName: request.status == .accepted ? "checkmark.circle.fill" : "clock")
                .foregroundColor(request.status == .accepted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.status == .accepted ? "Stay accepted" : "Request pending")
                    .font(.subheadline).fontWeight(.semibold)
                Text("\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background((request.status == .accepted ? Color.green : Color.orange).opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private func openInMaps() {
        mapItems.first?.openInMaps(launchOptions: nil)
    }

    private func amenityRow(_ label: String, available: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(available ? .green : .secondary.opacity(0.75))
                .accessibilityHidden(true)
            Text(available ? label : "\(label) (not available)")
                .foregroundColor(available ? .primary : .secondary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
    }
}


#Preview {
    NavigationStack {
        HomeDetailPage(home: Home(
            hostUserID: "preview-host",
            hostName: "Michaela",
            address: Address(street: "40 Cummings Rd", city: "Brighton", state: "MA", zip: "02135"),
            description: "Spots misses you!",
            contactPreference: .inApp,
            hostMotivation: .eager,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 14, kidsAllowed: true, guestPetsAllowed: false),
            amenities: Amenities(
                hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
                hasMicrowave: true, hasTV: true, hasWifi: true,
                hasPrivateGuestBathroom: false, hostHasPets: true, parkingDetails: "Street parking",
                hasInUnitLaundry: true, hasCoinLaundryNearby: false,
                providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: true,
                foodProvision: .all
            )
        ))
        .environment(MessageStore())
        .environment(AuthManager())
        .environment(StayRequestStore())
        .environment(UserProfileStore())
    }
}

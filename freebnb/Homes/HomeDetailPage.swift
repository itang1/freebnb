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

    private enum MapState {
        case loading
        case loaded
        case failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: Host motivation
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

                // MARK: Details
                Text("Details")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest Rooms: \(home.numGuestRooms)")
                    Text("Max Guests: \(home.maxGuests)")
                    Text("Max Stay: \(home.maxStayDays) night\(home.maxStayDays == 1 ? "" : "s")")
                    if !home.sleepingCounts.isEmpty {
                        Text("Sleeping Arrangements: \(home.sleepingArrangementsDescription)")
                    }
                }
                .font(.subheadline)

                // MARK: Guests & Space
                Text("Guests & Space")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Kids Allowed", available: home.kidsAllowed)
                    amenityRow("Guest Can Bring Pets", available: home.guestPetsAllowed)
                    amenityRow("Host Has Pets", available: home.hostHasPets)
                }
                .font(.subheadline)

                // MARK: Amenities
                Text("Amenities")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Air Conditioning", available: home.hasAC)
                    amenityRow("Heating", available: home.hasHeating)
                    amenityRow("Kitchen", available: home.hasKitchen)
                    amenityRow("Fridge Space", available: home.hasFridgeSpace)
                    amenityRow("Microwave", available: home.hasMicrowave)
                    amenityRow("TV", available: home.hasTV)
                    amenityRow("Wifi", available: home.hasWifi)
                }
                .font(.subheadline)

                // MARK: Rooms & Laundry
                Text("Rooms & Laundry")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Private Guest Bathroom", available: home.hasPrivateGuestBathroom)
                    amenityRow("In-unit Laundry", available: home.hasInUnitLaundry)
                    amenityRow("Coin Laundry Nearby", available: home.hasCoinLaundryNearby)
                }
                .font(.subheadline)

                // MARK: Parking
                if !home.parkingDetails.isEmpty {
                    Text("Parking")
                        .font(.headline)
                    Text(home.parkingDetails)
                        .font(.subheadline)
                }

                // MARK: Provisions
                Text("Provisions")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Pillows", available: home.providesPillows)
                    amenityRow("Blankets", available: home.providesBlankets)
                    amenityRow("Towels", available: home.providesTowels)
                    amenityRow("Toiletries", available: home.providesToiletries)
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .foregroundColor(home.foodProvision == .none ? .secondary.opacity(0.75) : .green)
                            .accessibilityHidden(true)
                        Text("Food: \(home.foodProvision.displayName)")
                            .foregroundColor(home.foodProvision == .none ? .secondary.opacity(0.75) : .primary)
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
                        .flippedPrimaryColor()
                        .cornerRadius(10)
                }
                .disabled(mapState != .loaded)
            }
            .padding()
        }
        .onAppear(perform: startGeocoding)
        .onDisappear {
            geocodeTask?.cancel()
            geocodeTask = nil
        }
        .navigationTitle(home.hostName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    if authManager.authMethod != .guest {
                        let saved = userProfileStore.isSaved(home.id)
                        Button {
                            Task { try? await userProfileStore.toggleSavedListing(home.id) }
                        } label: {
                            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                                .accessibilityLabel(saved ? "Remove bookmark" : "Bookmark listing")
                        }
                    }
                    ShareLink(
                        item: "\(home.hostName) is hosting in \(home.address.city), \(home.address.state) on FreeBNB. Ask them for an invite!",
                        subject: Text("FreeBNB Listing")
                    )
                }
            }
        }
        .background(Color.creamWhite)
    }

    // MARK: - Map section

    @ViewBuilder
    private var mapSection: some View {
        switch mapState {
        case .loading:
            ProgressView("Loading map...")
                .frame(maxWidth: .infinity)
                .frame(height: 250)
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

    // MARK: - Geocoding

    private func startGeocoding() {
        guard mapState == .loading else { return }
        let address = formattedAddress
        let hostName = home.hostName
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
                        .flippedPrimaryColor()
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
            numGuestRooms: 1, maxGuests: 2, maxStayDays: 14,
            sleepingArrangements: ["bed": 1],
            kidsAllowed: true, guestPetsAllowed: false, hostHasPets: true,
            hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
            hasMicrowave: true, hasTV: true, hasWifi: true,
            hasPrivateGuestBathroom: false, parkingDetails: "Street parking",
            hasInUnitLaundry: true, hasCoinLaundryNearby: false,
            providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: true,
            foodProvision: .all
        ))
        .environment(MessageStore())
        .environment(AuthManager())
        .environment(StayRequestStore())
        .environment(UserProfileStore())
    }
}

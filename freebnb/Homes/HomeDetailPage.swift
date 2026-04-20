//
//  HomeDetailPage.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI
import MapKit

struct HomeDetailPage: View {
    let home: Home

    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
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
                // MARK: Details
                Text("Details")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest Rooms: \(home.numGuestRooms)")
                    Text("Max Guests: \(home.maxGuests)")
                    Text("Max Stay: \(home.maxStayDays) night\(home.maxStayDays == 1 ? "" : "s")")
                    if !home.sleepingArrangements.isEmpty {
                        Text("Sleeping Arrangements: \(home.sleepingArrangements.sorted(by: { $0.key < $1.key }).map { "\($0.value) \(sleepingLabel(for: $0.key))" }.joined(separator: ", "))")
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
        geocodeTask = Task {
            do {
                let coordinate = try await geocodeAddress(home.address)
                guard !Task.isCancelled else { return }
                let placemark = MKPlacemark(coordinate: coordinate)
                let item = MKMapItem(placemark: placemark)
                item.name = home.hostName
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

    private func geocodeAddress(_ address: Address) async throws -> CLLocationCoordinate2D {
        try await withCheckedThrowingContinuation { continuation in
            CLGeocoder().geocodeAddressString(formattedAddress) { placemarks, error in
                if let coordinate = placemarks?.first?.location?.coordinate {
                    continuation.resume(returning: coordinate)
                } else {
                    continuation.resume(throwing: error ?? CoordinateError.noResults)
                }
            }
        }
    }

    private enum CoordinateError: Error {
        case noResults
    }

    private var formattedAddress: String {
        "\(home.address.street), \(home.address.city), \(home.address.state) \(home.address.zip)"
    }

    // MARK: - Contact section

    @ViewBuilder
    private var contactSection: some View {
        switch home.contactPreference {
        case .inApp:
            NavigationLink {
                MessagingPage(otherUserID: home.hostUserID, otherName: home.hostName)
            } label: {
                Label("Message \(home.hostName)", systemImage: "message.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.appTeal)
                    .flippedPrimaryColor()
                    .cornerRadius(10)
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

    // MARK: - Helpers

    private func openInMaps() {
        guard let coordinate = mapItems.first?.placemark.coordinate else { return }
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = home.hostName
        item.openInMaps(launchOptions: nil)
    }

    private func sleepingLabel(for rawValue: String) -> String {
        SleepingSurface(rawValue: rawValue)?.displayName ?? rawValue
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
        HomeDetailPage(home: sampleData.randomElement()!)
            .environment(MessageStore())
            .environment(AuthManager())
    }
}

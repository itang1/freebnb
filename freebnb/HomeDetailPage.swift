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

    @EnvironmentObject var messageStore: MessageStore
    @State private var region = MKCoordinateRegion()
    @State private var mapItems: [MKMapItem] = []
    @State private var isLoaded = false
    
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
                        Text("Sleeping Arrangements: \(home.sleepingArrangements.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { "\($0.value) \(sleepingLabel(for: $0.key))" }.joined(separator: ", "))")
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
                        Text("Food: \(home.foodProvision.rawValue)")
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

                Text("Contact Host")
                    .font(.headline)

                contactSection

                Spacer(minLength: 10)

                Text("View on Map")
                    .font(.headline)
                
                Text("\(home.address.street), \(home.address.city), \(home.address.state) \(home.address.zip)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if isLoaded {
                    Map(initialPosition: .region(region)) {
                        ForEach(mapItems, id: \.self) { item in
                            Marker(item.name ?? "Location", coordinate: item.placemark.coordinate)
                        }
                    }
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView("Loading map...")
                        .frame(height: 250)
                }
                
                Button(action: openInMaps) {
                    Text("Open in Apple Maps")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("Coral"))
                        .flippedPrimaryColor()
                        .cornerRadius(10)
                }
            }
            .padding()
        }
        .onAppear {
            geocodeAddress(home.address) { coordinate in
                guard let coordinate = coordinate else { return }
                let placemark = MKPlacemark(coordinate: coordinate)
                let item = MKMapItem(placemark: placemark)
                item.name = home.hostName
                mapItems = [item]
                region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                isLoaded = true
            }
        }
        .navigationTitle(home.hostName)
        .background(Color.creamWhite)
    }
    
    
    @ViewBuilder
    private var contactSection: some View {
        switch home.contactPreference {
        case .inApp:
            NavigationLink {
                MessagingPage(home: home)
            } label: {
                Label("Message \(home.hostName)", systemImage: "message.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color("AppTeal"))
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
                            .foregroundColor(Color("AppTeal"))
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

    private func sleepingLabel(for surface: SleepingSurface) -> String {
        switch surface {
        case .bed: return "bed"
        case .airMattress: return "air mattress"
        case .couch: return "couch"
        case .futon: return "futon"
        case .floorMat: return "floor mat"
        }
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

    func openInMaps() {
        guard let coordinate = mapItems.first?.placemark.coordinate else { return }
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = home.hostName
        item.openInMaps(launchOptions: nil)
    }
    
    func geocodeAddress(_ address: Address, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let fullAddress = "\(address.street), \(address.city), \(address.state) \(address.zip)"
        CLGeocoder().geocodeAddressString(fullAddress) { placemarks, error in
            completion(placemarks?.first?.location?.coordinate)
        }
    }
}


#Preview {
    NavigationStack {
        HomeDetailPage(home: sampleData.randomElement()!)
            .environmentObject(MessageStore())
    }
}

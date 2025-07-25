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
    
    @State private var region = MKCoordinateRegion()
    @State private var mapItems: [MKMapItem] = []
    @State private var isLoaded = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(home.hostName)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("\(home.address.street), \(home.address.city), \(home.address.state) \(home.address.zip)")
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Text("Details")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rooms: \(home.numRooms)")
                    Text("Guests: \(home.maxGuests)")
                    Text("Pet Friendly: \(home.isPetFriendly ? "Yes" : "No")")
                    Text("Private Guest Bathroom: \(home.hasGuestBathroom ? "Yes" : "No")")
                    Text("In-unit Laundry: \(home.hasInUnitLaundry ? "Yes" : "No")")
                }
                .font(.subheadline)
                
                if let description = home.description, !description.isEmpty {
                    Text(description)
                        .padding(.top, 10)
                }
                
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
                        .background(Color.accentColor)
                        .foregroundColor(.white)
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
    HomeDetailPage(home: sampleData.first!)
}

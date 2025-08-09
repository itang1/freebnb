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
                
                Spacer(minLength: 10)

                Text("Details")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest Rooms: \(home.numGuestRooms)")
                    Text("Max Guests: \(home.maxGuests)")
                    Text("Max Stay: \(home.maxStayLengthDays) night\(home.maxStayLengthDays == 1 ? "" : "s")")
                    Text("Kids Allowed: \(home.kidsAllowed ? "Yes" : "No")")
                    Text("Pets Allowed: \(home.petsAllowed ? "Yes" : "No")")
                    Text("Pets on Premises: \(home.petsOnPremises ? "Yes" : "No")")
                    Text("Private Guest Bathroom: \(home.hasPrivateGuestBathroom ? "Yes" : "No")")
                    Text("In-unit Laundry: \(home.hasInUnitLaundry ? "Yes" : "No")")
                    Text("Coin Laundry Nearby: \(home.hasCoinLaundry ? "Yes" : "No")")
                    Text("Air Conditioning: \(home.hasAC ? "Yes" : "No")")
                    Text("Heating: \(home.hasHeating ? "Yes" : "No")")
                    Text("Kitchen: \(home.hasKitchen ? "Yes" : "No")")
                    Text("Fridge Space: \(home.hasFridgeSpace ? "Yes" : "No")")
                    Text("TV: \(home.hasTV ? "Yes" : "No")")
                    Text("Wifi: \(home.hasWifi ? "Yes" : "No")")
                    Text("Microwave: \(home.hasMicrowave ? "Yes" : "No")")
                    Text("Pillows Provided: \(home.providesPillows ? "Yes" : "No")")
                    Text("Blankets Provided: \(home.providesBlankets ? "Yes" : "No")")
                    Text("Towels Provided: \(home.providesTowels ? "Yes" : "No")")
                    Text("Toiletries Provided: \(home.providesToiletries ? "Yes" : "No")")
                }
                .font(.subheadline)
                
                
                if let description = home.description, !description.isEmpty {
                        Spacer(minLength: 10)
                        Text("Memo")
                            .bold(true)
                        Text(description)
                }
                
                if isLoaded {
                    Spacer(minLength: 10)
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
                        .background(.mintGreen)
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
    HomeDetailPage(home: sampleData.randomElement()!)
}

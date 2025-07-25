//
//  HomeCard.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI
import Foundation

struct Address: Codable, Hashable {
    var street: String
    var city: String
    var state: String
    var zip: String
}

struct Home: Identifiable, Hashable, Equatable {
    let id = UUID()
    var hostName: String
    var address: Address
    var numRooms: Int
    var maxGuests: Int
    var isPetFriendly: Bool
    var hasGuestBathroom: Bool
    var hasInUnitLaundry: Bool
    var hasWifi: Bool
    var description: String?
    
    static func == (lhs: Home, rhs: Home) -> Bool {
        return lhs.id == rhs.id
    }
}


struct HomeCard: View {
    let listing: Home
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "house.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .padding(.trailing, 8)
                
                VStack(alignment: .leading) {
                    Text(listing.hostName)
                        .font(.headline)
                    Text("\(listing.address.city), \(listing.address.state)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("\(listing.numRooms) room\(listing.numRooms == 1 ? "" : "s"), \(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    HStack {
                        if listing.hasWifi {
                            Image(systemName: "wifi.circle")
                                .foregroundColor(.black)
                        }
                        if listing.isPetFriendly {
                            Image(systemName: "pawprint.circle")
                                .foregroundColor(.brown)
                        }
                        if listing.hasGuestBathroom {
                            Image(systemName: "toilet.circle")
                                .foregroundColor(.blue)
                        }
                        if listing.hasInUnitLaundry {
                            Image(systemName: "washer.circle")
                                .foregroundColor(.indigo)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .foregroundStyle(.tint)
                .opacity(0.25)
                .brightness(-0.1)
        }
    }
}

#Preview {
    HomeCard(listing: sampleData.first!)
}

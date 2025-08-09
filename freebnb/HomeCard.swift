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

enum SleepingSurface: String, Hashable {
    case bed
    case airMattress
    case couch
    case futon
    case floorMat
}

struct Home: Identifiable, Hashable, Equatable {
    // Unique identifier
    let id = UUID()
    
    // Host and location
    var hostName: String
    var address: Address
    var description: String?
    
    // Capacity
    var numGuestRooms: Int
    var maxGuests: Int
    var maxStayLengthDays: Int
    var sleepingArrangements: [SleepingSurface: Int]
    var kidsAllowed: Bool
    var petsAllowed: Bool
    var petsOnPremises: Bool
    
    // Comfort and amenities
    var hasAC: Bool
    var hasHeating: Bool
    var hasKitchen: Bool
    var hasFridgeSpace: Bool
    var hasMicrowave: Bool
    var hasTV: Bool
    var hasWifi: Bool
    
    // Other rooms
    var hasPrivateGuestBathroom: Bool
    var parkingDetails: String
    var hasInUnitLaundry: Bool
    var hasCoinLaundry: Bool
    
    // Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    
    
    // Function to  determine when two Home instances are considered equal
    static func == (lhs: Home, rhs: Home) -> Bool {
        return lhs.id == rhs.id
    }
}


struct HomeCard: View {
    let listing: Home

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                // House icon
                Image(systemName: "house.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .padding(.trailing, 8)
                    .foregroundColor(.coralPink)

                VStack(alignment: .leading, spacing: 10) {
                    
                    // Name and Location
                    HStack(spacing: 4) {
                        Text(listing.hostName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        
                        Text(" | ")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("\(listing.address.city), \(listing.address.state)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                    }
                    
                    // Guest count
                    Text("\(listing.numGuestRooms) guest room\(listing.numGuestRooms == 1 ? "" : "s"), \(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    // Icons
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if listing.hasWifi {
                                IconView(systemName: "wifi.square.fill", color: .indigo)
                            }
                            if listing.hasTV {
                                IconView(systemName: "tv", color: .indigo)
                            }
                            if listing.hasKitchen {
                                IconView(systemName: "stove", color: .indigo)
                            }
                            if listing.hasMicrowave {
                                IconView(systemName: "microwave.fill", color: .indigo)
                            }
                            if listing.hasFridgeSpace {
                                IconView(systemName: "carrot", color: .indigo)
                            }
                            if listing.hasAC {
                                IconView(systemName: "wind.snow", color: .indigo)
                            }
                            if listing.hasHeating {
                                IconView(systemName: "heat.waves", color: .indigo)
                            }
                        }

                        HStack(spacing: 8) {
                            if listing.petsAllowed {
                                IconView(systemName: "pawprint.fill", color: .blue)
                            }
                            if listing.kidsAllowed {
                                IconView(systemName: "figure.and.child.holdinghands", color: .blue)
                            }
                            if listing.hasPrivateGuestBathroom {
                                IconView(systemName: "toilet.fill", color: .blue)
                            }
                            if listing.hasInUnitLaundry {
                                IconView(systemName: "washer.fill", color: .blue)
                            }
                            if listing.hasCoinLaundry {
                                IconView(systemName: "washer.fill", color: .blue)
                            }
                            if listing.providesPillows {
                                IconView(systemName: "bed.double", color: .blue)
                            }
                            if listing.providesTowels {
                                IconView(systemName: "shower.fill", color: .blue)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.skyBlue)
                .opacity(0.5)
        }

    }
}

// Reusable icon view
struct IconView: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundColor(color)
            .imageScale(.large)
    }
}

#Preview {
    HomeCard(listing: sampleData.randomElement()!)
}

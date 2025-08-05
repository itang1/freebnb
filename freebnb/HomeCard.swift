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
                Image(systemName: "house.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text(listing.hostName)
                            .font(.headline)
                        Text(" | \(listing.address.city), \(listing.address.state)")
                            .font(.headline)
                            .foregroundColor(.gray)
                    }

                    Text("\(listing.numGuestRooms) guest room\(listing.numGuestRooms == 1 ? "" : "s"), \(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.black)

                    // Icons section (split in two rows if needed)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if listing.hasWifi {
                                IconView(systemName: "wifi.circle", color: .black)
                            }
                            if listing.hasTV {
                                IconView(systemName: "tv.circle", color: .blue)
                            }
                            if listing.hasKitchen {
                                IconView(systemName: "fork.knife.circle", color: .green)
                            }
                            if listing.hasMicrowave {
                                IconView(systemName: "microwave.circle", color: .orange)
                            }
                            if listing.hasFridgeSpace {
                                IconView(systemName: "cube.box.fill", color: .cyan)
                            }
                            if listing.hasAC {
                                IconView(systemName: "wind.circle", color: .mint)
                            }
                            if listing.hasHeating {
                                IconView(systemName: "flame.circle", color: .red)
                            }
                        }

                        HStack(spacing: 8) {
                            if listing.petsAllowed {
                                IconView(systemName: "pawprint.circle", color: .brown)
                            }
                            if listing.kidsAllowed {
                                IconView(systemName: "figure.2.circle", color: .pink)
                            }
                            if listing.hasPrivateGuestBathroom {
                                IconView(systemName: "toilet.circle", color: .blue)
                            }
                            if listing.hasInUnitLaundry {
                                IconView(systemName: "washer.circle", color: .indigo)
                            } else if listing.hasCoinLaundry {
                                IconView(systemName: "dollarsign.circle", color: .gray)
                            }
                            if listing.providesPillows {
                                IconView(systemName: "pillow", color: .teal)
                            }
                            if listing.providesTowels {
                                IconView(systemName: "drop.circle", color: .blue)
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
                .foregroundStyle(.tint)
                .opacity(0.25)
                .brightness(-0.1)
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
    HomeCard(listing: sampleData.last!)
}

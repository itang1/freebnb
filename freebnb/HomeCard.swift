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
    // MARK: Unique identifier
    let id = UUID()
    
    // MARK: Host and location
    var hostName: String
    var address: Address
    var description: String?
    
    // MARK: Capacity
    var numGuestRooms: Int
    var maxGuests: Int
    var maxStayDays: Int
    var sleepingArrangements: [SleepingSurface: Int]
    var kidsAllowed: Bool
    var guestPetsAllowed: Bool
    var hostHasPets: Bool
    
    // MARK: Comfort and amenities
    var hasAC: Bool
    var hasHeating: Bool
    var hasKitchen: Bool
    var hasFridgeSpace: Bool
    var hasMicrowave: Bool
    var hasTV: Bool
    var hasWifi: Bool
    
    // MARK: Other rooms
    var hasPrivateGuestBathroom: Bool
    var parkingDetails: String
    var hasInUnitLaundry: Bool
    var hasCoinLaundryNearby: Bool
    
    // MARK: Provisions
    var providesPillows: Bool
    var providesBlankets: Bool
    var providesTowels: Bool
    var providesToiletries: Bool
    
    
    // Function to determine when two Home instances are considered equal
    static func == (lhs: Home, rhs: Home) -> Bool {
        return lhs.id == rhs.id
    }
}

func AmenityRow(
    isVisible: Bool,
    @ViewBuilder content: () -> some View
) -> some View {
    Group {
        if isVisible {
            HStack(spacing: 8) {
                content()
            }
        } else {
            EmptyView()
        }
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
                    .foregroundColor(Color("AppTeal"))

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
                    Text("\(listing.numGuestRooms) guest room\(listing.numGuestRooms == 1 ? "" : "s"), \(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s"), \(listing.maxStayDays) days max")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    // Icons
                    VStack(alignment: .leading, spacing: 10) {
                        // MARK: Guests, Space & Laundry
                        AmenityRow(
                            isVisible: listing.kidsAllowed ||
                                       listing.guestPetsAllowed ||
                                       listing.hostHasPets || listing.hasPrivateGuestBathroom ||
                            listing.hasInUnitLaundry ||
                            listing.hasCoinLaundryNearby
                        ) {
                            if listing.kidsAllowed {
                                IconView(systemName: "figure.2.and.child.holdinghands", color: .purple)
                            }
                            if listing.guestPetsAllowed {
                                IconView(systemName: "pawprint.fill", color: .purple)
                            }
                            if listing.hostHasPets {
                                IconView(systemName: "pet.carrier.fill", color: .purple)
                            }
                            if listing.hasPrivateGuestBathroom {
                                IconView(systemName: "toilet.fill", color: .purple)
                            }
                            if listing.hasInUnitLaundry {
                                IconView(systemName: "washer.fill", color: .purple)
                            }
                            if listing.hasCoinLaundryNearby {
                                IconView(systemName: "washer.circle.fill", color: .purple)
                            }
                        }

                        // MARK: Comfort & Amenities
                        AmenityRow(
                            isVisible: listing.hasAC ||
                                       listing.hasHeating ||
                                       listing.hasKitchen ||
                                       listing.hasFridgeSpace ||
                                       listing.hasMicrowave ||
                                       listing.hasTV ||
                                       listing.hasWifi
                        ) {
                            if listing.hasAC {
                                IconView(systemName: "snowflake", color: .blue)
                            }
                            if listing.hasHeating {
                                IconView(systemName: "heat.waves", color: .blue)
                            }
                            if listing.hasKitchen {
                                IconView(systemName: "stove", color: .blue)
                            }
                            if listing.hasFridgeSpace {
                                IconView(systemName: "refrigerator.fill", color: .blue)
                            }
                            if listing.hasMicrowave {
                                IconView(systemName: "microwave.fill", color: .blue)
                            }
                            if listing.hasTV {
                                IconView(systemName: "tv.fill", color: .blue)
                            }
                            if listing.hasWifi {
                                IconView(systemName: "wifi", color: .blue)
                            }
                        }

                        // MARK: Provisions
                        AmenityRow(
                            isVisible: listing.providesPillows ||
                                       listing.providesBlankets ||
                                       listing.providesTowels ||
                                       listing.providesToiletries
                        ) {
                            if listing.providesPillows {
                                IconView(systemName: "bed.double.fill", color: Color("Coral"))
                            }
                            if listing.providesBlankets {
                                IconView(systemName: "rectangle.portrait.and.arrow.right", color: Color("Coral"))
                            }
                            if listing.providesTowels {
                                IconView(systemName: "shower.fill", color: Color("Coral"))
                            }
                            if listing.providesToiletries {
                                IconView(systemName: "bubbles.and.sparkles.fill", color: Color("Coral"))
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
                .fill(Color.skyBlue.opacity(0.5))
//                .opacity(0.5)
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


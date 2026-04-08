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
        VStack(alignment: .leading, spacing: 0) {
            // Header strip
            HStack {
                Image(systemName: "house.fill")
                    .font(.subheadline)

                Text(listing.hostName)
                    .font(.headline)

                Text("—")
                    .font(.subheadline)
                    .opacity(0.8)

                Text("\(listing.address.city), \(listing.address.state)")
                    .font(.subheadline)
                    .opacity(0.8)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .opacity(0.8)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.appTeal)

            // Body
            VStack(alignment: .leading, spacing: 10) {
                // Guest count in a pill
                Text("\(listing.numGuestRooms) guest room\(listing.numGuestRooms == 1 ? "" : "s"), \(listing.maxGuests) guest\(listing.maxGuests == 1 ? "" : "s"), \(listing.maxStayDays) days max")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.appTeal.opacity(0.15))
                    .cornerRadius(12)

                // Amenity icons in colored chips
                VStack(alignment: .leading, spacing: 8) {
                        // MARK: Guests, Space & Laundry
                        AmenityRow(
                            isVisible: listing.kidsAllowed ||
                                       listing.guestPetsAllowed ||
                                       listing.hostHasPets || listing.hasPrivateGuestBathroom ||
                            listing.hasInUnitLaundry ||
                            listing.hasCoinLaundryNearby
                        ) {
                            if listing.kidsAllowed {
                                ChipIcon(systemName: "figure.2.and.child.holdinghands", color: .purple)
                            }
                            if listing.guestPetsAllowed {
                                ChipIcon(systemName: "pawprint.fill", color: .purple)
                            }
                            if listing.hostHasPets {
                                ChipIcon(systemName: "pet.carrier.fill", color: .purple)
                            }
                            if listing.hasPrivateGuestBathroom {
                                ChipIcon(systemName: "toilet.fill", color: .purple)
                            }
                            if listing.hasInUnitLaundry {
                                ChipIcon(systemName: "washer.fill", color: .purple)
                            }
                            if listing.hasCoinLaundryNearby {
                                ChipIcon(systemName: "washer.circle.fill", color: .purple)
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
                                ChipIcon(systemName: "snowflake", color: .blue)
                            }
                            if listing.hasHeating {
                                ChipIcon(systemName: "heat.waves", color: .blue)
                            }
                            if listing.hasKitchen {
                                ChipIcon(systemName: "stove", color: .blue)
                            }
                            if listing.hasFridgeSpace {
                                ChipIcon(systemName: "refrigerator.fill", color: .blue)
                            }
                            if listing.hasMicrowave {
                                ChipIcon(systemName: "microwave.fill", color: .blue)
                            }
                            if listing.hasTV {
                                ChipIcon(systemName: "tv.fill", color: .blue)
                            }
                            if listing.hasWifi {
                                ChipIcon(systemName: "wifi", color: .blue)
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
                                ChipIcon(systemName: "bed.double.fill", color: Color("Coral"))
                            }
                            if listing.providesBlankets {
                                ChipIcon(systemName: "rectangle.portrait.and.arrow.right", color: Color("Coral"))
                            }
                            if listing.providesTowels {
                                ChipIcon(systemName: "shower.fill", color: Color("Coral"))
                            }
                            if listing.providesToiletries {
                                ChipIcon(systemName: "bubbles.and.sparkles.fill", color: Color("Coral"))
                            }
                        }
                    }
                }
                .padding(16)
            }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.skyBlue.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.appTeal.opacity(0.15), radius: 8, x: 0, y: 5)

    }
}

// Amenity icon in a colored chip
struct ChipIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundColor(color)
            .padding(6)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    HomeCard(listing: sampleData.randomElement()!)
}


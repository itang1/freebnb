//
//  PreviewData.swift
//  freebnb
//
//  Canonical mock objects for #Preview blocks, so previews stop hand-rolling
//  model values inline and a model change breaks one file instead of twenty.
//  Not #if DEBUG-gated: #Preview bodies are compiled (then stripped) in release
//  configurations, so gating this would break archive builds.
//

import Foundation

enum PreviewData {
    static let viewerID = "preview-viewer"
    static let friendID = "preview-friend"

    static let amenities = Amenities(
        hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
        hasMicrowave: true, hasTV: false, hasWifi: true,
        hasPrivateGuestBathroom: true, hostHasPets: false,
        parkingDetails: "Street parking, permit not needed",
        hasInUnitLaundry: true, hasCoinLaundryNearby: false,
        providesPillows: true, providesBlankets: true, providesTowels: true,
        providesToiletries: false, foodProvision: .some,
        hasStepFreeEntry: true, hasElevator: false, hasAccessibleBathroom: false
    )

    static let home: Home = {
        var home = Home(
            hostUserID: friendID,
            hostName: "Maya",
            address: Address(city: "Portland", state: "OR", zip: "97205"),
            description: "Quiet guest room with a garden view. Coffee's always on.",
            contactPreference: .inApp,
            hostContactInfo: nil,
            hostMotivation: .eager,
            sleeping: Sleeping(
                numGuestRooms: 1,
                arrangements: ["bed": 1, "couch": 1],
                numBathrooms: 1,
                bedSizes: ["queen": 1]
            ),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
            amenities: amenities,
            cancellationPolicy: .flexible
        )
        home.id = "preview-home"
        home.latitude = 45.52
        home.longitude = -122.68
        home.createdAt = Date()
        return home
    }()

    static let homes: [Home] = {
        var second = home
        second.id = "preview-home-2"
        second.hostName = "Sam"
        second.address = Address(city: "Seattle", state: "WA", zip: "98101")
        second.hostMotivation = .open
        second.latitude = 47.61
        second.longitude = -122.33
        return [home, second]
    }()

    static let location = ListingLocation(street: "1234 SE Ash St", latitude: 45.5202, longitude: -122.6842)

    static let manual: HouseManual = {
        var manual = HouseManual()
        manual.checkInInstructions = "Lockbox on the porch rail, code 1234."
        manual.wifiNetwork = "MayasPlace"
        manual.wifiPassword = "welcome-guest"
        manual.keyHandoff = "Leave the key in the lockbox at checkout."
        manual.hostPhone = "555-0100"
        return manual
    }()

    static let stay = StayRequest(
        id: "preview-stay",
        listingID: home.id,
        listingCity: home.address.city,
        listingHostName: home.hostName,
        hostUserID: friendID,
        guestUserID: viewerID,
        checkIn: Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now,
        checkOut: Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now,
        guestNote: "In town for a conference, out most days.",
        guestCount: 2,
        status: .accepted
    )

    static let pendingStay: StayRequest = {
        var stay = PreviewData.stay
        stay.status = .pending
        return stay
    }()

    static let message = Message(
        id: "preview-message",
        senderUserID: friendID,
        text: "Sounds great, see you Friday!",
        timestamp: Date(),
        participants: [friendID, viewerID].sorted()
    )

    static let review = Review(
        stayRequestID: stay.id,
        listingID: home.id,
        authorUserID: friendID,
        subjectUserID: viewerID,
        role: .guestReviewingHost,
        rating: 5,
        publicComment: "Tidy, communicative, and great company. Anytime."
    )

    static let reference = CharacterReference(
        authorUserID: friendID,
        subjectUserID: viewerID,
        text: "We've been friends for a decade; you can hand them your keys."
    )

    static let reach = NetworkReach(
        hosts: [
            NetworkReach.HostReach(friendID: friendID, displayName: "Maya", homeCount: 2),
            NetworkReach.HostReach(friendID: "preview-friend-2", displayName: "Sam", homeCount: 1),
        ]
    )
}

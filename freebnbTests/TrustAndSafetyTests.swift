//
//  TrustAndSafetyTests.swift
//  freebnbTests
//
//  The pure logic behind the trust-and-safety surfaces: who may complete or
//  review a stay, how a reputation is phrased, and whether a friends-of-friends
//  listing is visible to a viewer the client can only judge by its ACL.
//

import Foundation
import Testing
@testable import freebnb

// MARK: - Fixtures

private func makeAmenities() -> Amenities {
    Amenities(
        hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
        hasMicrowave: false, hasTV: false, hasWifi: false,
        hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
        hasInUnitLaundry: false, hasCoinLaundryNearby: false,
        providesPillows: false, providesBlankets: false, providesTowels: false,
        providesToiletries: false, foodProvision: .none
    )
}

private func makeHome(
    id: String,
    hostUserID: String,
    visibility: ListingVisibility?,
    allowedViewerIDs: [String]? = nil
) -> Home {
    var home = Home(
        hostUserID: hostUserID,
        hostName: "Host",
        address: Address(city: "Town", state: "CA", zip: "00000"),
        description: nil,
        contactPreference: .inApp,
        hostContactInfo: nil,
        hostMotivation: .open,
        sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
        guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
        amenities: makeAmenities()
    )
    home.id = id
    home.visibility = visibility
    home.allowedViewerIDs = allowedViewerIDs
    home.createdAt = Date(timeIntervalSince1970: 1_000)
    return home
}

private func makeStay(
    id: String = "stay-1",
    hostUserID: String = "host",
    guestUserID: String = "guest",
    status: StayRequestStatus = .accepted,
    checkIn: Date,
    checkOut: Date
) -> StayRequest {
    StayRequest(
        id: id,
        listingID: "listing-1",
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: hostUserID,
        guestUserID: guestUserID,
        checkIn: checkIn,
        checkOut: checkOut,
        status: status
    )
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let yesterday = now.addingTimeInterval(-86_400)
private let tomorrow = now.addingTimeInterval(86_400)
private let nextWeek = now.addingTimeInterval(7 * 86_400)

// MARK: - Stay completion (feature 4)

@Test func acceptedStayThatHasBegunCanBeCompleted() {
    let stay = makeStay(checkIn: yesterday, checkOut: tomorrow)
    #expect(stay.canBeMarkedComplete(now: now))
}

@Test func futureStayCannotBeCompleted() {
    // The guard that stops a host from farming completed stays by accepting a
    // booking a year out and instantly "finishing" it.
    let stay = makeStay(checkIn: tomorrow, checkOut: nextWeek)
    #expect(!stay.canBeMarkedComplete(now: now))
}

@Test func onlyAcceptedStaysCanBeCompleted() {
    for status in [StayRequestStatus.pending, .declined, .cancelled, .completed] {
        let stay = makeStay(status: status, checkIn: yesterday, checkOut: tomorrow)
        #expect(!stay.canBeMarkedComplete(now: now), "\(status) should not be completable")
    }
}

// MARK: - Review eligibility (feature 1)

@Test func reviewRoleFollowsTheSideYouWereOn() {
    let stay = makeStay(status: .completed, checkIn: yesterday, checkOut: now)
    #expect(stay.reviewRole(for: "guest") == .guestReviewingHost)
    #expect(stay.reviewRole(for: "host") == .hostReviewingGuest)
    #expect(stay.reviewRole(for: "stranger") == nil)
}

@Test func onlyCompletedStaysUnlockReviews() {
    let stay = makeStay(status: .accepted, checkIn: yesterday, checkOut: tomorrow)
    #expect(stay.reviewRole(for: "guest") == nil)
}

@Test func reviewIDIsDeterministicPerStayAndAuthor() {
    // The rules require the document id to equal this, which is what makes a
    // second review of the same stay an overwrite rather than a new document.
    let review = Review(
        stayRequestID: "stay-7",
        listingID: "listing-1",
        authorUserID: "guest",
        subjectUserID: "host",
        role: .guestReviewingHost,
        rating: 5
    )
    #expect(review.id == "stay-7_guest")
    #expect(Review.id(stayRequestID: "stay-7", authorUserID: "guest") == review.id)
}

@Test func ratingIsClampedToTheLegalRange() {
    let low = Review(stayRequestID: "s", listingID: "l", authorUserID: "a", subjectUserID: "b", role: .hostReviewingGuest, rating: 0)
    let high = Review(stayRequestID: "s", listingID: "l", authorUserID: "a", subjectUserID: "b", role: .hostReviewingGuest, rating: 9)
    #expect(low.rating == 1)
    #expect(high.rating == 5)
}

@Test func averageRatingOfNoReviewsIsNilNotZero() {
    // Zero would render as a one-star host. Nothing is the honest answer.
    #expect([Review]().averageRating == nil)
}

// MARK: - Trust stats (feature 2)

@Test func responseRateTextRoundsToWholePercent() {
    var stats = TrustStats()
    stats.responseRate = 0.923
    #expect(stats.responseRateText == "92% response rate")
}

@Test func absentStatsProduceNoText() {
    let stats = TrustStats()
    #expect(stats.responseRateText == nil)
    #expect(stats.ratingText == nil)
    #expect(!stats.isVerified)
}

@Test func ratingTextNeedsAtLeastOneReview() {
    var stats = TrustStats()
    stats.averageRating = 4.75
    stats.reviewCount = 0
    #expect(stats.ratingText == nil)
    stats.reviewCount = 4
    #expect(stats.ratingText == "4.8 ★ (4)")
}

@Test func tenureReadsAsNewBelowOneYear() {
    let joined = Calendar.current.date(byAdding: .month, value: -6, to: now)!
    #expect(TrustStats.tenureText(joinedAt: joined, now: now) == "New here")
}

@Test func tenurePluralisesYears() {
    let oneYear = Calendar.current.date(byAdding: .year, value: -1, to: now)!
    let threeYears = Calendar.current.date(byAdding: .year, value: -3, to: now)!
    #expect(TrustStats.tenureText(joinedAt: oneYear, now: now) == "1 year on FreeBNB")
    #expect(TrustStats.tenureText(joinedAt: threeYears, now: now) == "3 years on FreeBNB")
    #expect(TrustStats.tenureText(joinedAt: nil, now: now) == nil)
}

@Test func mutualFriendSummaryNamesTwoThenCounts() {
    #expect(MutualFriends(count: 0, names: []).summary == nil)
    #expect(MutualFriends(count: 2, names: ["Priya", "Sam"]).summary == "Priya and Sam")
    #expect(MutualFriends(count: 5, names: ["Priya", "Sam"]).summary == "Priya, Sam and 3 others")
    // The callable resolves at most two names; a count with none still reads.
    #expect(MutualFriends(count: 3, names: []).summary == "3 mutual friends")
}

// MARK: - Graduated visibility (feature 7)

@Test func friendsOfFriendsListingIsVisibleThroughTheACL() {
    // The viewer is two hops from the host, which the client cannot verify: it
    // may only read its own friend edges. The server-built ACL is the evidence.
    let home = makeHome(id: "h", hostUserID: "host", visibility: .friendsOfFriends, allowedViewerIDs: ["host", "me"])
    let feed = HomeStore.feed(from: [home], myID: "me", friendIDs: [], blockedIDs: [])
    #expect(feed.map(\.id) == ["h"])
}

@Test func friendsOfFriendsListingIsHiddenWhenTheACLOmitsYou() {
    let home = makeHome(id: "h", hostUserID: "host", visibility: .friendsOfFriends, allowedViewerIDs: ["host"])
    let feed = HomeStore.feed(from: [home], myID: "me", friendIDs: [], blockedIDs: [])
    #expect(feed.isEmpty)
}

@Test func friendsOnlyListingIgnoresTheACLAndChecksTheFriendship() {
    // A stale ACL — a friend removed since the listing was last written — must
    // not keep showing the listing. Here the client *can* check the claim.
    let home = makeHome(id: "h", hostUserID: "host", visibility: .friendsOnly, allowedViewerIDs: ["host", "me"])
    #expect(HomeStore.feed(from: [home], myID: "me", friendIDs: [], blockedIDs: []).isEmpty)
    #expect(HomeStore.feed(from: [home], myID: "me", friendIDs: ["host"], blockedIDs: []).count == 1)
}

@Test func yourOwnRestrictedListingIsAlwaysVisibleToYou() {
    let home = makeHome(id: "h", hostUserID: "me", visibility: .friendsOfFriends, allowedViewerIDs: nil)
    #expect(HomeStore.feed(from: [home], myID: "me", friendIDs: [], blockedIDs: []).count == 1)
}

@Test func blockedHostsWinOverEveryVisibilityTier() {
    let home = makeHome(id: "h", hostUserID: "host", visibility: .everyone)
    #expect(HomeStore.feed(from: [home], myID: "me", friendIDs: ["host"], blockedIDs: ["host"]).isEmpty)
}

@Test func listingWithNoVisibilityReadsAsPublic() {
    let home = makeHome(id: "h", hostUserID: "host", visibility: nil)
    #expect(HomeStore.feed(from: [home], myID: "me", friendIDs: [], blockedIDs: []).count == 1)
}

// MARK: - Safety check-in (feature 5)

@Test func safetyMessageWithheldsTheAddressUntilItIsDisclosed() {
    let stay = makeStay(status: .pending, checkIn: tomorrow, checkOut: nextWeek)
    let message = SafetyCheckIn.message(stay: stay, guestName: "Irene", location: nil, manual: nil)
    #expect(message.contains("Area: Town"))
    #expect(!message.contains("Address:"))
    #expect(message.contains("shared once the host accepts"))
}

@Test func safetyMessageIncludesTheStreetOnceDisclosed() {
    let stay = makeStay(checkIn: tomorrow, checkOut: nextWeek)
    var manual = HouseManual()
    manual.hostPhone = "555-0100"
    let message = SafetyCheckIn.message(
        stay: stay,
        guestName: "Irene",
        location: ListingLocation(street: "12 Elm St", latitude: nil, longitude: nil),
        manual: manual
    )
    #expect(message.contains("Address: 12 Elm St, Town"))
    #expect(message.contains("Host phone: 555-0100"))
    #expect(!message.contains("Area: Town"))
}

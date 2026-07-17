//
//  BookedDatesTests.swift
//  freebnbTests
//
//  The listing-side of booked dates: a server-owned `bookedDateRanges` that the
//  client only decodes, rides back out on save, and merges with the host's blocked
//  ranges into one guest-facing "unavailable". The trigger that fills the field is
//  covered end-to-end against the emulator; these pin the client's half.
//

import Testing
import Foundation
@testable import freebnb

struct BookedDatesTests {
    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86_400)
    }

    /// A listing written before this field decodes with nil booked ranges rather
    /// than throwing — the same tolerance every added field owes the feed.
    @Test func legacyListingHasNoBookedRanges() throws {
        let json = """
        {
          "hostUserID": "host",
          "hostName": "Host",
          "address": { "city": "Pasadena", "state": "CA", "zip": "91103" },
          "sleeping": { "numGuestRooms": 1, "arrangements": { "bed": 1 } },
          "guestPolicy": { "maxGuests": 2, "maxStayDays": 7, "kidsAllowed": true, "guestPetsAllowed": false },
          "amenities": {
            "hasAC": true, "hasHeating": true, "hasKitchen": true, "hasFridgeSpace": false,
            "hasMicrowave": false, "hasTV": false, "hasWifi": true,
            "hasPrivateGuestBathroom": true, "hostHasPets": false, "parkingDetails": "Street",
            "hasInUnitLaundry": false, "hasCoinLaundryNearby": true,
            "providesPillows": true, "providesBlankets": true, "providesTowels": false,
            "providesToiletries": false, "foodProvision": "some"
          }
        }
        """
        let home = try JSONDecoder().decode(Home.self, from: Data(json.utf8))
        #expect(home.bookedDateRanges == nil)
        #expect(home.unavailableRanges.isEmpty)
    }

    /// The server writes it and the client must not drop it on the next save: the
    /// repository replaces the whole document, so a field that didn't survive an
    /// encode/decode round-trip would be wiped the next time the host edited.
    @Test func bookedRangesSurviveARoundTrip() throws {
        var home = HomeFixture.make()
        home.bookedDateRanges = [DateRange(start: day(10), end: day(14))]

        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))

        #expect(restored.bookedDateRanges?.count == 1)
        #expect(restored.bookedDateRanges?.first?.start == day(10))
        #expect(restored.bookedDateRanges?.first?.end == day(14))
    }

    /// The one thing guest surfaces read. Blocked and booked land in the same list
    /// so a booking renders exactly like a host-blocked day and nothing downstream
    /// can tell them apart.
    @Test func unavailableRangesMergesBlockedAndBooked() {
        var home = HomeFixture.make()
        home.blockedDateRanges = [DateRange(start: day(1), end: day(3))]
        home.bookedDateRanges = [DateRange(start: day(10), end: day(14))]

        let ranges = home.unavailableRanges
        #expect(ranges.count == 2)
        #expect(ranges.contains(DateRange(start: day(1), end: day(3))))
        #expect(ranges.contains(DateRange(start: day(10), end: day(14))))
    }

    /// Either side being empty must not swallow the other: a listing with only
    /// bookings is still unavailable on those days, and one with only blocks still
    /// blocks.
    @Test func unavailableRangesHandlesEitherSideEmpty() {
        var bookedOnly = HomeFixture.make()
        bookedOnly.bookedDateRanges = [DateRange(start: day(10), end: day(14))]
        #expect(bookedOnly.unavailableRanges.count == 1)

        var blockedOnly = HomeFixture.make()
        blockedOnly.blockedDateRanges = [DateRange(start: day(1), end: day(3))]
        #expect(blockedOnly.unavailableRanges.count == 1)
    }
}

//
//  BookedDatesTests.swift
//  freebnbTests
//
//  The listing side of booked dates: a server-owned `bookedDateRanges` the client
//  decodes, rides back out on save, and merges with blocked ranges into one
//  guest-facing "unavailable". The trigger is covered against the emulator; these pin the client's half.
//

import Testing
import Foundation
@testable import freebnb

struct BookedDatesTests {
    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86_400)
    }

    /// A stored listing with only the always-required fields plus the availability shape under test.
    /// Raw JSON, since the point is what comes off the wire and an encoder only emits the current shape.
    private static func legacyListingJSON(extraFields: String = "") -> String {
        """
        {
          \(extraFields)
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
    }

    /// The merged field must survive an encode/decode round trip; the repository replaces the whole document.
    @Test func unavailableRangesSurviveARoundTrip() throws {
        var home = HomeFixture.make()
        home.unavailableDateRanges = [DateRange(start: day(10), end: day(14))]

        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))

        #expect(restored.unavailableDateRanges?.count == 1)
        #expect(restored.unavailableDateRanges?.first?.start == day(10))
        #expect(restored.unavailableDateRanges?.first?.end == day(14))
    }

    /// The union the private document hands to the public one: blocked and booked in one list, unmarked. Buffer zero pins the pure merge.
    @Test func availabilityMergesBlockedAndBooked() {
        let availability = ListingAvailability(
            blockedDateRanges: [DateRange(start: day(1), end: day(3))],
            bookedDateRanges: [DateRange(start: day(10), end: day(14))],
            bufferHours: 0
        )

        let ranges = availability.unavailableRanges
        #expect(ranges.count == 2)
        #expect(ranges.contains(DateRange(start: day(1), end: day(3))))
        #expect(ranges.contains(DateRange(start: day(10), end: day(14))))
    }

    /// The buffer grows the booked half by whole days both sides before merging. A
    /// one-day buffer around a day 10 – 14 stay closes days 9 and 14; blocked days
    /// pass through, and the result carries no sign it is a buffer.
    @Test func bufferGrowsTheBookedHalfOnBothSides() {
        let availability = ListingAvailability(
            blockedDateRanges: [DateRange(start: day(1), end: day(3))],
            bookedDateRanges: [DateRange(start: day(10), end: day(14))],
            bufferHours: 24
        )

        let days = AvailabilityCalendar.blockedDays(in: availability.unavailableRanges)
        // The stay's own nights.
        #expect(days.contains(day(10)))
        #expect(days.contains(day(13)))
        // The buffer: the day before check-in and the checkout day the raw range leaves bookable.
        #expect(days.contains(day(9)))
        #expect(days.contains(day(14)))
        // Just outside the buffer on either side stays open.
        #expect(!days.contains(day(8)))
        #expect(!days.contains(day(15)))
        // The host's blocked days are not padded.
        #expect(days.contains(day(1)))
        #expect(!days.contains(day(0)))
    }

    /// A listing predating the buffer reads as the default, not zero, so no host has to opt in.
    @Test func availabilityMissingBufferDecodesAsTheDefault() throws {
        let restored = try JSONDecoder().decode(
            ListingAvailability.self,
            from: Data(#"{"bookedDateRanges":[{"start":864000,"end":1209600}]}"#.utf8)
        )
        #expect(restored.bufferHours == ListingAvailability.defaultBufferHours)
    }

    /// Either half being empty mustn't swallow the other.
    @Test func availabilityHandlesEitherHalfEmpty() {
        let bookedOnly = ListingAvailability(bookedDateRanges: [DateRange(start: day(10), end: day(14))])
        #expect(bookedOnly.unavailableRanges.count == 1)

        let blockedOnly = ListingAvailability(blockedDateRanges: [DateRange(start: day(1), end: day(3))])
        #expect(blockedOnly.unavailableRanges.count == 1)
    }

    /// A never-written private document decodes as an open calendar rather than throwing.
    @Test func absentAvailabilityHalvesDecodeAsEmpty() throws {
        let restored = try JSONDecoder().decode(ListingAvailability.self, from: Data("{}".utf8))
        #expect(restored.blockedDateRanges.isEmpty)
        #expect(restored.bookedDateRanges.isEmpty)
        #expect(restored.unavailableRanges.isEmpty)
    }

    // MARK: - Reading a listing written before the split

    /// The backfill runs after this ships, so legacy listings with the two public arrays must keep showing every closed day.
    @Test func legacyListingFallsBackToTheUnionOfBothFields() throws {
        let home = try JSONDecoder().decode(Home.self, from: Data(Self.legacyListingJSON(
            extraFields: """
            "blockedDateRanges": [{ "start": 86400, "end": 259200 }],
            "bookedDateRanges":  [{ "start": 864000, "end": 1209600 }],
            """
        ).utf8))

        #expect(home.unavailableRanges.count == 2)
        #expect(home.unavailableRanges.contains(DateRange(
            start: Date(timeIntervalSinceReferenceDate: 86_400),
            end: Date(timeIntervalSinceReferenceDate: 259_200)
        )))
        #expect(home.unavailableRanges.contains(DateRange(
            start: Date(timeIntervalSinceReferenceDate: 864_000),
            end: Date(timeIntervalSinceReferenceDate: 1_209_600)
        )))
    }

    /// The migrated field wins outright; a mid-backfill document with both shapes mustn't double-count.
    @Test func migratedFieldWinsOverTheLegacyPair() throws {
        let home = try JSONDecoder().decode(Home.self, from: Data(Self.legacyListingJSON(
            extraFields: """
            "unavailableDateRanges": [{ "start": 86400, "end": 259200 }],
            "blockedDateRanges": [{ "start": 86400, "end": 259200 }],
            "bookedDateRanges":  [{ "start": 864000, "end": 1209600 }],
            """
        ).utf8))

        #expect(home.unavailableRanges.count == 1)
    }

    /// Neither shape present is an open calendar, not a decode failure.
    @Test func listingWithNoAvailabilityKeysDecodes() throws {
        let home = try JSONDecoder().decode(Home.self, from: Data(Self.legacyListingJSON().utf8))
        #expect(home.unavailableDateRanges == nil)
        #expect(home.unavailableRanges.isEmpty)
    }

    // MARK: - The invariant, enforced

    /// The files allowed to name the two halves. Most code goes through
    /// `ListingAvailability` or the merged `Home.unavailableDateRanges`; adding a
    /// file here claims no guest can see it.
    private static let mayReadRawRanges: Set<String> = [
        "freebnb/Homes/ListingAvailability.swift",     // defines both halves
        "freebnb/Homes/Home.swift",                    // decodes the pre-split public shape
        "freebnb/Shared/HomesRepository.swift",        // merge-writes the blocked half
        "freebnb/Shared/InMemoryRepositories.swift",   // the test double for that write
        "freebnb/Homes/HomeStore.swift",               // manager-only: editor save and apply-to-all
        "freebnb/Homes/AvailabilityEditorView.swift",  // the host's editor, the one screen that sees them apart
    ]

    /// Everything from `//` to end of line, removed: the rule is about what code
    /// reads, and comments here name the split fields. Block comments aren't used.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// `Home.bookedDateRanges` asks callers to use `unavailableRanges`, but a comment
    /// alone let `ModifyStaySheet` validate against blocked ranges and leak which days
    /// were bookings. A comment can't fail a build; this can.
    @Test func onlyHostSurfacesNameTheSplitRanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // freebnbTests
            .deletingLastPathComponent()  // repo root
        let sources = root.appendingPathComponent("freebnb")

        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "couldn't walk \(sources.path)"
        )

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !Self.mayReadRawRanges.contains(relative) else { continue }
            let code = try Self.strippingComments(String(contentsOf: url, encoding: .utf8))
            if code.contains("bookedDateRanges") || code.contains("blockedDateRanges") {
                offenders.append(relative)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            These files name `bookedDateRanges`/`blockedDateRanges` directly: \
            \(offenders.sorted().joined(separator: ", ")). \
            Guest-facing code must read `Home.unavailableRanges`, so a booked day and \
            a host-blocked day stay indistinguishable. If the file is host-only, add it \
            to `mayReadRawRanges` above.
            """
        )
    }
}

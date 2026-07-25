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

    /// A stored listing carrying only the fields that have always been required,
    /// plus whatever availability shape the test is exercising. Written as raw
    /// JSON rather than built from `HomeFixture` because the point of these tests
    /// is what comes off the wire, and an encoder can only ever produce the
    /// current shape.
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

    /// The merged field must survive an encode/decode round-trip: the repository
    /// replaces the whole listing document, so a field that didn't would be wiped
    /// the next time the host edited anything.
    @Test func unavailableRangesSurviveARoundTrip() throws {
        var home = HomeFixture.make()
        home.unavailableDateRanges = [DateRange(start: day(10), end: day(14))]

        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))

        #expect(restored.unavailableDateRanges?.count == 1)
        #expect(restored.unavailableDateRanges?.first?.start == day(10))
        #expect(restored.unavailableDateRanges?.first?.end == day(14))
    }

    /// The union the private document hands to the public one. Blocked and booked
    /// land in one list in which nothing marks which was which. Buffer zero here,
    /// so this pins the pure merge without the turnover padding the next tests own.
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

    /// The turnover buffer grows the booked half by whole days on both sides
    /// before it merges. A one-day buffer around a stay booked day 10 – 14 closes
    /// day 9 (the day before check-in) and day 14 (the day after checkout, which
    /// the raw half-open range left open), while the host's blocked days pass
    /// through untouched. The published field carries the padded stay, so a guest
    /// reads it as unavailable with nothing to say it is a buffer rather than a
    /// booking.
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
        // The buffer: the day before check-in and the checkout day the raw range
        // would have left bookable.
        #expect(days.contains(day(9)))
        #expect(days.contains(day(14)))
        // Just outside the buffer on either side stays open.
        #expect(!days.contains(day(8)))
        #expect(!days.contains(day(15)))
        // The host's blocked days are not padded.
        #expect(days.contains(day(1)))
        #expect(!days.contains(day(0)))
    }

    /// A listing written before the buffer existed reads as the default, not zero,
    /// so it still gets its turnover day. This is the retroactive half of the
    /// feature: no host has to opt in for the gap to appear.
    @Test func availabilityMissingBufferDecodesAsTheDefault() throws {
        let restored = try JSONDecoder().decode(
            ListingAvailability.self,
            from: Data(#"{"bookedDateRanges":[{"start":864000,"end":1209600}]}"#.utf8)
        )
        #expect(restored.bufferHours == ListingAvailability.defaultBufferHours)
    }

    /// Either half being empty must not swallow the other: a listing with only
    /// bookings is still unavailable on those days, and one with only blocks still
    /// blocks.
    @Test func availabilityHandlesEitherHalfEmpty() {
        let bookedOnly = ListingAvailability(bookedDateRanges: [DateRange(start: day(10), end: day(14))])
        #expect(bookedOnly.unavailableRanges.count == 1)

        let blockedOnly = ListingAvailability(blockedDateRanges: [DateRange(start: day(1), end: day(3))])
        #expect(blockedOnly.unavailableRanges.count == 1)
    }

    /// A private document that has never been written decodes as an open calendar
    /// rather than throwing. It doesn't exist until a host blocks a day or a stay
    /// is accepted, and "no document" has to mean "nothing closed".
    @Test func absentAvailabilityHalvesDecodeAsEmpty() throws {
        let restored = try JSONDecoder().decode(ListingAvailability.self, from: Data("{}".utf8))
        #expect(restored.blockedDateRanges.isEmpty)
        #expect(restored.bookedDateRanges.isEmpty)
        #expect(restored.unavailableRanges.isEmpty)
    }

    // MARK: - Reading a listing written before the split

    /// The backfill runs after this ships, so for a while the app will read
    /// listings still carrying the two public arrays. Those have to keep showing
    /// every day they had closed. The failure this guards against is the quiet
    /// one: a host's blocked week decoding as nil and the listing accepting
    /// requests for dates it had ruled out.
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

    /// The migrated field wins outright. A document carrying both shapes — which
    /// is what a listing looks like mid-backfill if a write interleaves — must not
    /// double-count its closed days.
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

    /// Neither shape present is an open calendar, not a decode failure — a listing
    /// that has never blocked a day has no availability keys at all.
    @Test func listingWithNoAvailabilityKeysDecodes() throws {
        let home = try JSONDecoder().decode(Home.self, from: Data(Self.legacyListingJSON().utf8))
        #expect(home.unavailableDateRanges == nil)
        #expect(home.unavailableRanges.isEmpty)
    }

    // MARK: - The invariant, enforced rather than asked for politely

    /// The files allowed to name the two halves at all. Much shorter than it was
    /// before the split: the halves now live in one private document, so most of
    /// the code that used to reach for them goes through `ListingAvailability` or
    /// the merged `Home.unavailableDateRanges` instead. Adding a file here is a
    /// claim that no guest can see it.
    private static let mayReadRawRanges: Set<String> = [
        "freebnb/Homes/ListingAvailability.swift",     // defines both halves
        "freebnb/Homes/Home.swift",                    // decodes the pre-split public shape
        "freebnb/Shared/HomesRepository.swift",        // merge-writes the blocked half
        "freebnb/Shared/InMemoryRepositories.swift",   // the test double for that write
        "freebnb/Homes/HomeStore.swift",               // manager-only: editor save and apply-to-all
        "freebnb/Homes/AvailabilityEditorView.swift",  // the host's editor, the one screen that sees them apart
    ]

    /// Everything from `//` to end of line, removed. The rule is about what the
    /// code reads, not what the comments discuss: this very file, and the fix that
    /// prompted it, both name the split fields in prose to explain why not to touch
    /// them. Block comments aren't stripped because this codebase doesn't use them.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// `Home.bookedDateRanges` asks callers to "go through `unavailableRanges`,
    /// never this", and for a while a comment was the only thing enforcing it —
    /// which is exactly how `ModifyStaySheet`, a guest-facing sheet, ended up
    /// validating against `blockedDateRanges` alone and telling any guest which of
    /// a host's unavailable days were bookings. A comment can't fail a build; this
    /// can.
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

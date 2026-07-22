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

    // MARK: - The invariant, enforced rather than asked for politely

    /// The files allowed to name the split fields at all. Everything here is the
    /// host's own side of the calendar, where booked and blocked legitimately
    /// differ, plus the model that defines them and the save path that round-trips
    /// them. Adding a file to this list is a claim that no guest can see it.
    private static let mayReadRawRanges: Set<String> = [
        "freebnb/Homes/Home.swift",                    // defines both fields
        "freebnb/Homes/AvailabilityEditorView.swift",  // host's editor; booked is read-only there
        "freebnb/Homes/CreateListingViewModel.swift",  // carries both across an edit
        "freebnb/Homes/HomeStore.swift",               // "block these dates on all my homes"
        "freebnb/Stays/OfferStaySheet.swift",          // host offering; pairs with its own accepted-stay check
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

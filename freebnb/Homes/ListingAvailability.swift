//
//  ListingAvailability.swift
//  freebnb
//
//  The two halves of a listing's calendar, kept where only the people who manage
//  the listing can read them: `homes/{id}/private/availability`.
//
//  The public listing document publishes one field, `unavailableDateRanges`, and
//  it is their union. That split is the whole point. Firestore has no field-level
//  read rules — a client that may read a document reads every field in it — so
//  keeping `blockedDateRanges` and `bookedDateRanges` on the world-readable
//  listing meant any guest who could see the listing could subtract one from the
//  other and learn exactly which nights the home was occupied, no matter what the
//  UI drew. A merged field is the only version of "unavailable" that stays merged
//  once it leaves the server.
//
//  Guests never read this document. Note that this is a tighter gate than the
//  sibling `private/location`, which an accepted guest may read: knowing the
//  street you were invited to is the point of being accepted, whereas knowing
//  which of a host's closed days were bookings never is.
//

import Foundation

struct ListingAvailability: Codable, Hashable, Sendable {
    /// Days the host has closed by hand. Theirs to edit, and the only half a
    /// client ever writes.
    var blockedDateRanges: [DateRange] = []

    /// Days an accepted stay has taken. Server-owned: recomputed from the
    /// listing's accepted stays by `onStayRequestWritten`, never authored by a
    /// client, and pinned as unwritable in `firestore.rules`. A host sees these
    /// in their own editor as filled and locked, because a day someone is
    /// arriving for is not a day they can hand to someone else.
    var bookedDateRanges: [DateRange] = []

    /// What the public listing document publishes. The one thing a guest ever
    /// sees, and the reason a booking and a closed week are the same fact to them.
    var unavailableRanges: [DateRange] { blockedDateRanges + bookedDateRanges }

    /// Both halves absent decodes as an empty calendar rather than throwing: the
    /// document doesn't exist at all until a host first blocks a day or a stay is
    /// first accepted, and "no document" has to mean "nothing closed".
    enum CodingKeys: String, CodingKey {
        case blockedDateRanges, bookedDateRanges
    }

    init(blockedDateRanges: [DateRange] = [], bookedDateRanges: [DateRange] = []) {
        self.blockedDateRanges = blockedDateRanges
        self.bookedDateRanges = bookedDateRanges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedDateRanges = try c.decodeIfPresent([DateRange].self, forKey: .blockedDateRanges) ?? []
        bookedDateRanges  = try c.decodeIfPresent([DateRange].self, forKey: .bookedDateRanges)  ?? []
    }
}

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

    /// The turnover gap the host wants guaranteed around every confirmed stay, in
    /// hours (feature: turnover buffer). The published calendar grows each booked
    /// range by this much on both sides, so the day before a check-in and the day
    /// after a checkout close automatically and the host is never handed back-to-
    /// back guests with no time to reset. Lives here, in the managers-only
    /// document, rather than on the public listing: a guest who knew the buffer
    /// could subtract it from an unavailable stretch and recover the booking under
    /// it, which is the one thing the merged calendar exists to prevent.
    var bufferHours: Int = ListingAvailability.defaultBufferHours

    /// One turnover day. Enough that a checkout and the next check-in never land
    /// on the same date, which is the gap the feature exists to guarantee, and the
    /// value a listing that never touched the setting is treated as having.
    static let defaultBufferHours = 24

    /// A week of turnover is more than any spare-couch host needs, and the ceiling
    /// keeps the padded ranges small. Mirrored by the `bufferHours` bound in
    /// `firestore.rules`.
    static let maxBufferHours = 168

    /// What the public listing document publishes. The one thing a guest ever
    /// sees, and the reason a booking, a closed week, and a stay's turnover buffer
    /// are the same fact to them: the booked half is grown by the buffer before it
    /// is merged with the host's blocked days.
    var unavailableRanges: [DateRange] {
        blockedDateRanges + AvailabilityCalendar.buffered(bookedDateRanges, bufferHours: bufferHours)
    }

    /// Every field absent decodes as an empty calendar rather than throwing: the
    /// document doesn't exist at all until a host first blocks a day, sets a
    /// buffer, or a stay is first accepted, and "no document" has to mean "nothing
    /// closed, default buffer".
    enum CodingKeys: String, CodingKey {
        case blockedDateRanges, bookedDateRanges, bufferHours
    }

    init(
        blockedDateRanges: [DateRange] = [],
        bookedDateRanges: [DateRange] = [],
        bufferHours: Int = ListingAvailability.defaultBufferHours
    ) {
        self.blockedDateRanges = blockedDateRanges
        self.bookedDateRanges = bookedDateRanges
        self.bufferHours = bufferHours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedDateRanges = try c.decodeIfPresent([DateRange].self, forKey: .blockedDateRanges) ?? []
        bookedDateRanges  = try c.decodeIfPresent([DateRange].self, forKey: .bookedDateRanges)  ?? []
        // Absent on every document written before the buffer existed, which must
        // read as the default rather than zero: a listing that predates the
        // feature still gets its turnover day.
        bufferHours       = try c.decodeIfPresent(Int.self, forKey: .bufferHours) ?? ListingAvailability.defaultBufferHours
    }
}

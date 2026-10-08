//
//  ListingAvailability.swift
//  freebnb
//
//  The two halves of a listing's calendar, in `homes/{id}/private/availability`, readable
//  only by managers. The public listing publishes just their union
//  (`unavailableDateRanges`): Firestore has no field-level read rules, so keeping both
//  halves on the readable listing let any guest subtract one from the other and learn
//  which nights were occupied. Guests never read this document, a tighter gate than
//  `private/location` (an accepted guest may read that, since the street is the point of acceptance).
//

import Foundation

struct ListingAvailability: Codable, Hashable, Sendable {
    /// Days the host closed by hand; the only half a client writes.
    var blockedDateRanges: [DateRange] = []

    /// Days an accepted stay took. Server-owned, recomputed by `onStayRequestWritten`
    /// and unwritable per `firestore.rules`. Hosts see them filled and locked.
    var bookedDateRanges: [DateRange] = []

    /// The turnover gap guaranteed around every confirmed stay, in hours. The published
    /// calendar grows each booked range by it on both sides. Kept in this managers-only
    /// document, since a guest who knew the buffer could subtract it and recover the booking.
    var bufferHours: Int = ListingAvailability.defaultBufferHours

    /// One turnover day: keeps a checkout and the next check-in off the same date; the default for listings that never set it.
    static let defaultBufferHours = 24

    /// A week is more than a spare-couch host needs and keeps padded ranges small. Mirrors the `bufferHours` bound in `firestore.rules`.
    static let maxBufferHours = 168

    /// What the public listing publishes, the only thing a guest sees: the booked half grown by the buffer, merged with blocked days.
    var unavailableRanges: [DateRange] {
        blockedDateRanges + AvailabilityCalendar.buffered(bookedDateRanges, bufferHours: bufferHours)
    }

    /// Absent fields decode as an empty calendar, since the document doesn't exist until a first block, buffer or accepted stay.
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
        // Absent before the buffer existed; reads as the default, not zero.
        bufferHours       = try c.decodeIfPresent(Int.self, forKey: .bufferHours) ?? ListingAvailability.defaultBufferHours
    }
}

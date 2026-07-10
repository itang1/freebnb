//
//  EmergencyContact.swift
//  freebnb
//
//  The person a guest tells about a stay (feature 5). Stored in the guest's
//  owner-only `users/{uid}/private/profile` subdocument, which nobody else — not
//  the host, not another guest — can read.
//
//  The contact is not a FreeBNB account and gets no server-side notification.
//  Sharing a stay composes the message on-device and hands it to the system share
//  sheet, so the address travels through the guest's own Messages or Mail and
//  never through a third party. That is both the cheapest design and the one with
//  the smallest disclosure surface: FreeBNB never learns who the contact is
//  beyond what the guest chose to store, and never transmits the address anywhere
//  new. Server-side delivery is written up in TODO_MANUAL.md.
//

import Foundation

struct EmergencyContact: Codable, Hashable, Sendable {
    /// What the guest calls them: "Mum", "Priya", "my roommate".
    var name: String
    /// A phone number or email, kept as free text because it is only ever shown
    /// back to the guest as a reminder of who they picked.
    var contact: String

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds from the raw Firestore map; nil when unset or malformed.
    init?(firestore map: [String: Any]?) {
        guard let map,
              let name = map["name"] as? String,
              let contact = map["contact"] as? String
        else { return nil }
        self.name = name
        self.contact = contact
    }

    init(name: String, contact: String) {
        self.name = name
        self.contact = contact
    }

    var firestoreValue: [String: String] {
        ["name": name, "contact": contact]
    }
}

// MARK: - The message a guest sends

enum SafetyCheckIn {
    /// The "here is where I'll be" note, assembled from only what this viewer is
    /// actually entitled to see. A guest whose stay hasn't been accepted has no
    /// street address, so neither does the message — it degrades to the city
    /// rather than pretending to a precision it doesn't have.
    static func message(
        stay: StayRequest,
        guestName: String,
        location: ListingLocation?,
        manual: HouseManual?
    ) -> String {
        var lines = [
            "\(guestName) is staying at a FreeBNB home.",
            "",
            "Host: \(stay.listingHostName)",
            "Dates: \(AppDateFormatters.mediumDate.string(from: stay.checkIn)) – \(AppDateFormatters.mediumDate.string(from: stay.checkOut))"
        ]

        if let street = location?.street, !street.isEmpty {
            lines.append("Address: \(street), \(stay.listingCity)")
        } else {
            lines.append("Area: \(stay.listingCity)")
            lines.append("(The exact address is shared once the host accepts the stay.)")
        }

        if let phone = manual?.hostPhone, !phone.isEmpty {
            lines.append("Host phone: \(phone)")
        }

        lines.append("")
        lines.append("If you don't hear from me by \(AppDateFormatters.mediumDate.string(from: stay.checkOut)), check in on me.")
        return lines.joined(separator: "\n")
    }
}

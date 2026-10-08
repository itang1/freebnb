//
//  EmergencyContact.swift
//  freebnb
//
//  The person a guest tells about a stay, stored in the guest's owner-only `users/{uid}/private/profile`.
//  The contact isn't a FreeBNB account and gets no server notification: sharing composes the message on-device
//  and hands it to the share sheet, so the address travels via the guest's own Messages or Mail, smallest
//  disclosure surface. Server-side delivery is in TODO_MANUAL.md.
//

import Foundation

struct EmergencyContact: Codable, Hashable, Sendable {
    /// What the guest calls them: "Mum", "Priya", "my roommate".
    var name: String
    /// Free text, since it's only shown back to the guest as a reminder of who they picked.
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
    /// The "here is where I'll be" note, from only what this viewer may see; without an accepted stay it
    /// degrades to the city.
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

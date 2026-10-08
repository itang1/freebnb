//
//  HouseManual.swift
//  freebnb
//
//  The host's check-in guide: getting in, wifi, quirks. Progressively disclosed like the street address, at
//  `homes/{id}/private/manual`, readable by the host and accepted guests, so a wifi password or door code never rides the feed.
//

import Foundation

struct HouseManual: Codable, Hashable, Sendable {
    var checkInInstructions: String = ""
    var wifiNetwork: String = ""
    var wifiPassword: String = ""
    var keyHandoff: String = ""
    var houseNotes: String = ""
    /// A number the host will reveal to an accepted guest for arrival-day coordination; distinct from the public `hostContactInfo`.
    var hostPhone: String = ""

    /// True when the host filled nothing in, to decide whether to show the manual to a guest at all.
    var isEmpty: Bool {
        checkInInstructions.isEmpty && wifiNetwork.isEmpty && wifiPassword.isEmpty
            && keyHandoff.isEmpty && houseNotes.isEmpty && hostPhone.isEmpty
    }
}

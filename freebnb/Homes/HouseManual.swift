//
//  HouseManual.swift
//  freebnb
//
//  The host-authored check-in guide for a listing: how to get in, the wifi, and
//  any house quirks. Like the exact street address it is progressively disclosed
//  — stored at `homes/{id}/private/manual` and readable only by the host and a
//  guest whose stay has been accepted (feature 15). Kept off the public listing
//  document so a wifi password or door code never rides along with the feed.
//

import Foundation

struct HouseManual: Codable, Hashable, Sendable {
    var checkInInstructions: String = ""
    var wifiNetwork: String = ""
    var wifiPassword: String = ""
    var keyHandoff: String = ""
    var houseNotes: String = ""
    /// A number the host is willing to reveal to an accepted guest for arrival-day
    /// coordination. Distinct from the public `hostContactInfo` on the listing.
    var hostPhone: String = ""

    /// True when the host has filled nothing in — used to decide whether to show
    /// the manual to a guest at all.
    var isEmpty: Bool {
        checkInInstructions.isEmpty && wifiNetwork.isEmpty && wifiPassword.isEmpty
            && keyHandoff.isEmpty && houseNotes.isEmpty && hostPhone.isEmpty
    }
}

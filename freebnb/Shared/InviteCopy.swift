//
//  InviteCopy.swift
//  freebnb
//
//  Share-sheet invite messages, in one place so every surface tells the same
//  story: an invite is a personal vouch, not a broadcast. FreeBNB never touches
//  the address book, so a hand-delivered message like these is the only way the
//  graph grows; the copy has to carry the "why join" on its own.
//

import Foundation

enum InviteCopy {
    /// The query item naming who sent an invite. Read by `DeepLinkRouter`, and
    /// by the web landing page in `admin/i/index.html`.
    static let inviterQueryItem = "from"

    /// The Firebase Hosting site the invite link points at, and the path it uses.
    ///
    /// These three constants are the contract between four places: the link this
    /// file builds, the routing in `DeepLinkRouter`, the
    /// `apple-app-site-association` file that tells iOS to open the app for this
    /// path, and the `firebase.json` rewrite that serves it. `InviteLinkTests`
    /// checks them against the on-disk web files, so changing one alone fails the
    /// build rather than quietly breaking every invite.
    static let webHost = "freebnb-6814a.web.app"
    static let webPath = "/i"
    static let customScheme = "freebnb"

    /// A link that opens the app on the Friends tab with the sender's own card
    /// already on screen, ready to add.
    ///
    /// An `https` Universal Link rather than the `freebnb://` scheme, because a
    /// custom scheme only resolves on a phone that already has the app, which is
    /// exactly not the person being invited: for them it did nothing at all. This
    /// opens the app when it is installed and a web page explaining FreeBNB when
    /// it is not.
    ///
    /// It carries the sender's user ID and nothing else, and it takes no action:
    /// opening it never creates a friend connection, it only saves the recipient
    /// from having to remember and spell a display name. The graph is still only
    /// ever changed by an explicit tap on "Add", answered by an explicit "Accept"
    /// at the other end, so a forged or forwarded link buys a sender nothing they
    /// could not get by being searched for by name.
    ///
    /// `senderID` is nil until the signed-in user's profile loads; the link then
    /// degrades to the plain one, which lands on Friends with the search bar
    /// empty.
    static func inviteURL(senderID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = webHost
        components.path = webPath
        if let senderID, !senderID.isEmpty {
            components.queryItems = [URLQueryItem(name: inviterQueryItem, value: senderID)]
        }
        // Force-unwrap is safe: compile-time constant URL.
        return components.url ?? URL(string: "https://\(webHost)\(webPath)")!
    }

    /// The pre-Universal-Link form of the same invite. Still parsed on the way in
    /// (links already sent have to keep working), and still what the web landing
    /// page hands to a phone that has the app, since a page cannot re-trigger the
    /// Universal Link that just failed to open it.
    static func customSchemeInviteURL(senderID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = customScheme
        components.host = "invite"
        if let senderID, !senderID.isEmpty {
            components.queryItems = [URLQueryItem(name: inviterQueryItem, value: senderID)]
        }
        return components.url ?? URL(string: "\(customScheme)://invite")!
    }

    /// The general "join me" invite, framed as vouching. On a friends-only app
    /// the feed is empty until a friend shows up, so a personal invite genuinely
    /// is what unlocks it; the copy says so as an offer, never as pressure.
    static func vouch(inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "FreeBNB is a free home-sharing app that only ever shows you places from your own friends. "
            + "No strangers, no fees, and it never touches your contacts. "
            + "I'm vouching for you; if you'd like in, install the app and "
            + closing(inviterName, senderID: senderID)
    }

    /// Sent from an empty city search. The moment someone plans a trip and has
    /// no friend listed there yet is the highest-intent invite moment in the
    /// app: they already know exactly whose couch they want.
    static func tripIntent(city: String, inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "I'm planning a trip to \(city) and I'd love to crash with you. "
            + "FreeBNB is a free, friends-only home-sharing app; if you join, I can send a real request with dates instead of a vague text. "
            + "If you're up for it, "
            + closing(inviterName, senderID: senderID)
    }

    /// Sent from a feed that has friends but no listings: an open question about
    /// hosting, with the choice left entirely to the recipient. Works whether or
    /// not they are already on FreeBNB.
    static func askToHost(inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "Got a couch or a guest room? If you put it on FreeBNB, friends like me could stay with you without the group-chat scramble. "
            + "It's free, always, and only friends you approve can ever see it. "
            + "If you're curious, "
            + closing(inviterName, senderID: senderID)
    }

    /// "It's Maya. " when the profile has loaded, nothing otherwise: the message
    /// arrives from the sender's own phone, so a missing name reads fine while a
    /// placeholder like "It's A friend" would not.
    private static func intro(_ inviterName: String?) -> String {
        inviterName.map { "It's \($0). " } ?? ""
    }

    /// How every invite ends: the link, and what tapping it does.
    ///
    /// An identified link opens on the sender's own card, so the recipient never
    /// has to remember how the sender spells their name. Without an ID there is
    /// nothing to open onto, so the message falls back to asking them to search.
    private static func closing(_ inviterName: String?, senderID: String?) -> String {
        guard senderID?.isEmpty == false else {
            return "search for \(searchTarget(inviterName)) once you're in: "
                + inviteURL().absoluteString
        }
        return "this link will open my profile in the app, where you can add me: "
            + inviteURL(senderID: senderID).absoluteString
    }

    private static func searchTarget(_ inviterName: String?) -> String {
        inviterName ?? "me"
    }
}

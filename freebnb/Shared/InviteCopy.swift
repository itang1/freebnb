//
//  InviteCopy.swift
//  freebnb
//
//  Share-sheet invite messages in one place, so every surface tells the same story: an invite
//  is a personal vouch, not a broadcast. FreeBNB never reads the address book, so these carry the "why join".
//

import Foundation

enum InviteCopy {
    /// The query item naming the sender; read by `DeepLinkRouter` and `admin/i/index.html`.
    static let inviterQueryItem = "from"

    /// The Hosting site and path the invite link uses. These constants are the contract
    /// between this file, `DeepLinkRouter`, `apple-app-site-association` and the
    /// `firebase.json` rewrite; `InviteLinkTests` checks them against the web files.
    static let webHost = "freebnb-6814a.web.app"
    static let webPath = "/i"
    static let customScheme = "freebnb"

    /// A link that opens the Friends tab with the sender's card ready to add. A
    /// Universal Link, since the `freebnb://` scheme does nothing for someone without
    /// the app (it opens a web page explaining FreeBNB instead). It carries only the
    /// sender's ID and takes no action: friending still needs an explicit "Add" and
    /// "Accept", so a forged link buys nothing a name search wouldn't. With no
    /// `senderID` yet, it lands on Friends with an empty search bar.
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

    /// The pre-Universal-Link form: still parsed so sent links keep working, and what
    /// the web landing page hands a phone with the app (it can't re-trigger the failed Universal Link).
    static func customSchemeInviteURL(senderID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = customScheme
        components.host = "invite"
        if let senderID, !senderID.isEmpty {
            components.queryItems = [URLQueryItem(name: inviterQueryItem, value: senderID)]
        }
        return components.url ?? URL(string: "\(customScheme)://invite")!
    }

    /// The general "join me" invite, framed as vouching: the feed is empty until a friend shows up, offered not pressed.
    static func vouch(inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "FreeBNB is a free home-sharing app that only ever shows you places from your own friends. "
            + "No strangers, no fees, and it never touches your contacts. "
            + "I'm vouching for you; if you'd like in, install the app and "
            + closing(inviterName, senderID: senderID)
    }

    /// Sent from an empty city search, the highest-intent invite moment: they know whose couch they want.
    static func tripIntent(city: String, inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "I'm planning a trip to \(city) and I'd love to crash with you. "
            + "FreeBNB is a free, friends-only home-sharing app; if you join, I can send a real request with dates instead of a vague text. "
            + "If you're up for it, "
            + closing(inviterName, senderID: senderID)
    }

    /// Sent from a feed with friends but no listings: an open question about hosting, choice left to the recipient.
    static func askToHost(inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "Got a couch or a guest room? If you put it on FreeBNB, friends like me could stay with you without the group-chat scramble. "
            + "It's free, always, and only friends you approve can ever see it. "
            + "If you're curious, "
            + closing(inviterName, senderID: senderID)
    }

    /// "It's Maya. " once the profile has loaded, else nothing (a placeholder like "It's A friend" would read badly).
    private static func intro(_ inviterName: String?) -> String {
        inviterName.map { "It's \($0). " } ?? ""
    }

    /// How every invite ends: the link and what tapping it does. Without a sender ID
    /// there's nothing to open onto, so it asks them to search instead.
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

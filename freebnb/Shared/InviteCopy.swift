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
    /// The query item naming who sent an invite. Read by `DeepLinkRouter` and
    /// mirrored in `FreeBNBApp.handleIncomingURL`.
    static let inviterQueryItem = "from"

    /// A link that opens the app on the Friends tab with the sender's own card
    /// already on screen, ready to add.
    ///
    /// It carries the sender's user ID and nothing else, and it still takes no
    /// action: opening it never creates a friend connection, it only saves the
    /// recipient from having to remember and spell a display name. The graph is
    /// still only ever changed by an explicit tap on "Add", answered by an
    /// explicit "Accept" at the other end, so a forged or forwarded link buys a
    /// sender nothing they could not get by being searched for by name.
    ///
    /// `senderID` is nil until the signed-in user's profile loads; the link then
    /// degrades to the plain one, which lands on Friends with the search bar
    /// empty.
    static func inviteURL(senderID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "freebnb"
        components.host = "invite"
        if let senderID, !senderID.isEmpty {
            components.queryItems = [URLQueryItem(name: inviterQueryItem, value: senderID)]
        }
        // Force-unwrap is safe: compile-time constant URL.
        return components.url ?? URL(string: "freebnb://invite")!
    }

    /// The general "join me" invite, framed as vouching. On a friends-only app
    /// the feed is empty until a friend shows up, so a personal invite genuinely
    /// is what unlocks it; the copy says so as an offer, never as pressure.
    static func vouch(inviterName: String?, senderID: String? = nil) -> String {
        intro(inviterName)
            + "FreeBNB is a free home-sharing app that only ever shows you places from your own friends. "
            + "No strangers, no fees, and it never touches your contacts. "
            + "I'm vouching for you; if you'd like in, install the app and search for \(searchTarget(inviterName)) so we can connect: "
            + inviteURL(senderID: senderID).absoluteString
    }

    /// Sent from an empty city search. The moment someone plans a trip and has
    /// no friend listed there yet is the highest-intent invite moment in the
    /// app: they already know exactly whose couch they want.
    static func tripIntent(city: String, inviterName: String?) -> String {
        intro(inviterName)
            + "I'm planning a trip to \(city) and I'd love to crash with you. "
            + "FreeBNB is a free, friends-only home-sharing app; if you join, I can send a real request with dates instead of a vague text. "
            + "Search for \(searchTarget(inviterName)) if you're up for it: "
            + inviteURL().absoluteString
    }

    /// Sent from a feed that has friends but no listings: an open question about
    /// hosting, with the choice left entirely to the recipient. Works whether or
    /// not they are already on FreeBNB.
    static func askToHost(inviterName: String?) -> String {
        intro(inviterName)
            + "Got a couch or a guest room? If you put it on FreeBNB, friends like me could stay with you without the group-chat scramble. "
            + "It's free, always, and only friends you approve can ever see it. "
            + "Search for \(searchTarget(inviterName)) if you're curious: "
            + inviteURL().absoluteString
    }

    /// "It's Maya. " when the profile has loaded, nothing otherwise: the message
    /// arrives from the sender's own phone, so a missing name reads fine while a
    /// placeholder like "It's A friend" would not.
    private static func intro(_ inviterName: String?) -> String {
        inviterName.map { "It's \($0). " } ?? ""
    }

    private static func searchTarget(_ inviterName: String?) -> String {
        inviterName ?? "me"
    }
}

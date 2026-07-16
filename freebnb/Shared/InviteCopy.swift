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
    /// A plain link that just opens the app. It carries no identity and takes no
    /// action: opening it never creates a friend connection. Once both people are
    /// on FreeBNB they add each other in-app, through search and an accepted
    /// request, so there is nothing here to spoof or act on.
    static var inviteURL: URL {
        var components = URLComponents()
        components.scheme = "freebnb"
        components.host = "invite"
        // Force-unwrap is safe: compile-time constant URL.
        return components.url ?? URL(string: "freebnb://invite")!
    }

    /// The general "join me" invite, framed as vouching. On a friends-only app
    /// the feed is empty until a friend shows up, so a personal invite genuinely
    /// is what unlocks it; the copy says so instead of asking for a favor.
    static func vouch(inviterName: String?) -> String {
        intro(inviterName)
            + "FreeBNB is a free home-sharing app that only ever shows you places from your own friends. "
            + "No strangers, no fees, and it never touches your contacts. I'm vouching for you. "
            + "Install the app, then search for \(searchTarget(inviterName)) so we can connect: "
            + inviteURL.absoluteString
    }

    /// Sent from an empty city search. The moment someone plans a trip and has
    /// no friend listed there yet is the highest-intent invite moment in the
    /// app: they already know exactly whose couch they want.
    static func tripIntent(city: String, inviterName: String?) -> String {
        intro(inviterName)
            + "I'm planning a trip to \(city) and I'd rather crash with you than with strangers. "
            + "FreeBNB is a free, friends-only home-sharing app; join it and I can request a stay properly. "
            + "Search for \(searchTarget(inviterName)) once you're in: "
            + inviteURL.absoluteString
    }

    /// Sent from a feed that has friends but no listings: a nudge that asks for
    /// one specific thing, listing a place. Works whether or not the recipient
    /// is already on FreeBNB.
    static func nudgeHost(inviterName: String?) -> String {
        intro(inviterName)
            + "Got a couch or a guest room? Put it on FreeBNB so friends like me can finally stay with you the easy way. "
            + "It's free, always, and only friends you approve can ever see it. "
            + "Search for \(searchTarget(inviterName)) once you're in: "
            + inviteURL.absoluteString
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

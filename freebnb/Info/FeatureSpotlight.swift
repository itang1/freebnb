//
//  FeatureSpotlight.swift
//  freebnb
//
//  The "Feature Spotlight" content: short, hand-written pieces that introduce one
//  feature at a time and how to get the most from it. Unlike `WhatsNew` (a
//  version-gated changelog), this is an evergreen, self-paced column. Add a new
//  `SpotlightArticle` to the front of the list whenever a new piece is written;
//  newest first, no version or network involved.
//

import Foundation

/// A single spotlight piece. `summary` is the one-line teaser shown in the list;
/// `body` is the full read shown on its own page.
struct SpotlightArticle: Identifiable, Hashable {
    let icon: String
    let title: String
    let date: String
    let summary: String
    let body: String
    var id: String { title }
}

enum FeatureSpotlight {
    /// Newest first. Prepend new pieces here.
    static let articles: [SpotlightArticle] = [
        SpotlightArticle(
            icon: "message.fill",
            title: "Messaging a host is how you ask to stay",
            date: "July 2026",
            summary: "There's no separate \"book now\" button, and that's on purpose.",
            body: """
            FreeBNB doesn't have a "book now" button, and it never will. A stay here starts the way it would in real life: you say hello.

            Open a listing and tap Message. That drops you into a conversation with the host, and once you're there you'll find a Request a Stay button right in the chat. Pick your dates, send it over, and the host accepts or declines without either of you leaving the thread.

            Why do it this way? Because you're staying with someone you know, or someone a friend knows. A quick message ("hey, would the last week of August work?") is warmer, and it means the details get sorted before anyone commits. Everything about a stay, the request, the yes, the check-in notes, lives in that one conversation, so you never have to go hunting for it later.
            """
        ),
        SpotlightArticle(
            icon: "lock.fill",
            title: "Why the address stays hidden until you're accepted",
            date: "July 2026",
            summary: "You'll see the neighborhood up front, and the front door once it's a yes.",
            body: """
            Look at any listing before you've been accepted and you'll see the city and a soft circle on the map, not a street address. That's deliberate.

            A home someone has opened up to friends isn't a hotel, and its exact location isn't public information. So until a host accepts your stay, FreeBNB shows only the general area, enough to know whether a place is convenient, not enough to find someone's front door.

            The moment your stay is accepted, the exact address unlocks, the map pin snaps to the real spot, and the host's house manual (check-in details, wifi, quirks of the place) becomes available to you. It's the digital version of a friend handing you the keys once you've made a plan.
            """
        ),
        SpotlightArticle(
            icon: "calendar",
            title: "Reading a host's availability at a glance",
            date: "July 2026",
            summary: "Blocked dates are visible before you ask, so you can pick times that actually work.",
            body: """
            Every listing shows an availability calendar for the next few months. Hosts block off the dates they can't have guests, and you see those blocks before you send a single message.

            It's a small thing that saves an awkward back-and-forth. Instead of asking "are you free in June?" and waiting, you can glance at the calendar, see what's open, and request dates you already know might work.

            Hosting? Keep your calendar current from your listing's settings. Blocking a week you'll be traveling, or that you simply want to yourself, is the easiest way to get requests for times you can actually say yes to.
            """
        )
    ]
}

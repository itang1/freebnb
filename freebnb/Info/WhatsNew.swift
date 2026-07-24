//
//  WhatsNew.swift
//  freebnb
//
//  A static, hand-curated list of what shipped, newest first. `WhatsNewPage` renders
//  it, and `ContentView` auto-presents the latest entry once per version bump.
//  Keeping it here (not fetched) means the changelog ships with the build it
//  describes and needs no network or billing. A highlight can carry a `longRead` for
//  a deeper explanation, folding in what used to be the separate "Feature Spotlight"
//  page.
//

import Foundation

/// One shipped change within a release.
struct ReleaseHighlight: Identifiable, Hashable {
    let icon: String
    let title: String
    let detail: String
    /// An optional deeper explanation of this highlight: why it works the way it does,
    /// not just what it does. A highlight with a `longRead` renders as a tappable card
    /// that pushes a reader page; one without renders as a plain row. This absorbed
    /// the old, separate "Feature Spotlight" column, since both were the same idea
    /// (an evergreen note about one feature) wearing two different pages.
    var longRead: String? = nil
    var id: String { title }
}

/// A single app version's worth of highlights.
struct Release: Identifiable, Hashable {
    /// Marketing version, matched against `Bundle.main.appVersionString` to decide
    /// whether to auto-present. The first element of `WhatsNew.releases` is treated
    /// as "current".
    let version: String
    let date: String
    /// Optional welcome blurb shown above the highlights. Used for the very first
    /// release to greet the reader; later releases can leave it nil.
    var intro: String? = nil
    let highlights: [ReleaseHighlight]
    var id: String { version }
}

enum WhatsNew {
    /// Newest first. `latest` is the head of this list and must carry the current
    /// marketing version so `shouldPresent` still fires on a real version bump. The
    /// entries below it are the pre-launch history: FreeBNB hasn't shipped an update
    /// to real users yet, so they're dated milestones rather than App Store releases,
    /// numbered 0.x to mark that. The next actual version bump prepends a new
    /// `Release` above "1.0".
    static let releases: [Release] = [
        Release(
            version: "1.0",
            date: "Late July 2026",
            highlights: [
                ReleaseHighlight(
                    icon: "hand.thumbsup.fill",
                    title: "Or let a host come to you",
                    detail: "Hosts can send an offer first instead of waiting on a request, so you might hear from someone before you even ask."
                ),
                ReleaseHighlight(
                    icon: "calendar.badge.clock",
                    title: "Real availability, not just yes or no",
                    detail: "Hosts set exactly which dates are open, and the calendar fills itself in as stays are accepted.",
                    longRead: """
                    When you pick dates for a stay request, the days a host can't have guests show up greyed out, right there in the date picker. You see them before you send anything, so the dates you ask for are dates that can actually work.

                    It's a small thing that saves an awkward back-and-forth. Instead of asking "are you free in June?" and waiting, you can open the request sheet, see what's open, and pick from that.

                    Hosting? Keep your blocked dates current from your listing's settings. Blocking a week you'll be traveling, or that you simply want to yourself, is the easiest way to get requests for times you can actually say yes to.
                    """
                ),
                ReleaseHighlight(
                    icon: "xmark.circle.fill",
                    title: "Plans change, and that's fine",
                    detail: "Either side can cancel an accepted stay, and the other person is notified right away."
                ),
                ReleaseHighlight(
                    icon: "person.crop.circle.badge.plus",
                    title: "Know who you're talking to",
                    detail: "Everyone has an avatar, and every listing has its own name, so a host with a few places to offer is easy to tell apart."
                ),
                ReleaseHighlight(
                    icon: "link",
                    title: "Invite with a link",
                    detail: "Send an invite as a link that opens straight on your friend's phone, no app switching required."
                ),
                ReleaseHighlight(
                    icon: "person.2.fill",
                    title: "A Friends tab of its own",
                    detail: "See your circle in one place instead of digging through chats."
                )
            ]
        ),
        Release(
            version: "0.4",
            date: "Mid-July 2026",
            intro: "This is the pass that made FreeBNB feel whole: browsing, messaging, requesting, and trusting each other, without a fee or a middleman anywhere in it.",
            highlights: [
                ReleaseHighlight(
                    icon: "house.fill",
                    title: "Stay with friends, for free",
                    detail: "Browse spare rooms and whole homes that people in your circle have opened up, and request a stay. Money never changes hands; it's friends hosting friends."
                ),
                ReleaseHighlight(
                    icon: "message.fill",
                    title: "Message and request, all in one chat",
                    detail: "Reach out to a host and request your stay in the same conversation. They accept or decline right there, and every trip you take and guest you host lives in the Stays tab.",
                    longRead: """
                    FreeBNB doesn't have a "book now" button, and it never will. A stay here starts the way it would in real life: you say hello.

                    Open a listing and tap Message. That drops you into a conversation with the host, and once you're there you'll find a Request a Stay button right in the chat. Pick your dates, send it over, and the host accepts or declines without either of you leaving the thread.

                    Why do it this way? Because you're staying with someone you know, or someone a friend knows. A quick message ("hey, would the last week of August work?") is warmer, and it means the details get sorted before anyone commits. Everything about a stay, the request, the yes, the check-in notes, lives in that one conversation, so you never have to go hunting for it later.
                    """
                ),
                ReleaseHighlight(
                    icon: "calendar",
                    title: "See everything before you go",
                    detail: "Check a host's availability, read reviews from past guests, and unlock the exact address and house manual the moment your stay is accepted.",
                    longRead: """
                    Look at any listing before you've been accepted and you'll see the city and a soft circle on the map, not a street address. That's deliberate.

                    A home someone has opened up to friends isn't a hotel, and its exact location isn't public information. So until a host accepts your stay, FreeBNB shows only the general area, enough to know whether a place is convenient, not enough to find someone's front door.

                    The moment your stay is accepted, the exact address unlocks, the map pin snaps to the real spot, and the host's house manual (check-in details, wifi, quirks of the place) becomes available to you. It's the digital version of a friend handing you the keys once you've made a plan.
                    """
                ),
                ReleaseHighlight(
                    icon: "checkmark.shield.fill",
                    title: "Hosts you can trust",
                    detail: "Mutual friends, past stays, and how quickly someone replies sit right up front, so you always know who's on the other side before you ask."
                ),
                ReleaseHighlight(
                    icon: "qrcode",
                    title: "Bring your people in",
                    detail: "Invite a friend by having them scan your QR code, and add a co-host to help you run a listing without handing it over."
                ),
                ReleaseHighlight(
                    icon: "wifi.slash",
                    title: "Works even offline",
                    detail: "Lose signal? A banner lets you know, and any message you send is queued and delivered automatically the moment you're back online."
                )
            ]
        ),
        Release(
            version: "0.3",
            date: "Early July 2026",
            intro: "Before this was ready for anyone outside the build, here's what came together.",
            highlights: [
                ReleaseHighlight(
                    icon: "star.bubble.fill",
                    title: "Reviews and trust, built in",
                    detail: "Guests and hosts could finally leave reviews, and a trust chip on a profile showed who'd been vetted."
                ),
                ReleaseHighlight(
                    icon: "lock.shield.fill",
                    title: "Friends only, for real",
                    detail: "FreeBNB dropped the idea of a public feed entirely. Every listing you see now comes from someone in your circle."
                ),
                ReleaseHighlight(
                    icon: "qrcode",
                    title: "Add a co-host, invite in person",
                    detail: "A co-host could help run a listing, and scanning a QR code became the fastest way to add a friend."
                ),
                ReleaseHighlight(
                    icon: "key.fill",
                    title: "More ways to sign in",
                    detail: "Google and email sign-in joined Apple, so signing up stopped requiring an iPhone specifically."
                ),
                ReleaseHighlight(
                    icon: "mappin.and.ellipse",
                    title: "Search wherever you're headed",
                    detail: "Move the map to a new city or neighborhood and search that area directly, instead of only seeing what's nearby."
                ),
                ReleaseHighlight(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Change your mind on the dates",
                    detail: "Sent a request already? Adjust the dates on a pending stay instead of cancelling and starting over."
                )
            ]
        ),
        Release(
            version: "0.2",
            date: "April 2026",
            intro: "This is when FreeBNB stopped being a mockup and became a real app.",
            highlights: [
                ReleaseHighlight(
                    icon: "person.badge.key.fill",
                    title: "Sign in for real",
                    detail: "Sign in with Apple and create an account, so a listing, a message, or a friend request is actually yours."
                ),
                ReleaseHighlight(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: "Message a host and ask to stay",
                    detail: "The feed moved to a live backend, and asking to stay became a real request a host could accept or decline, right inside the conversation."
                ),
                ReleaseHighlight(
                    icon: "square.and.pencil",
                    title: "List your own place",
                    detail: "Hosts could finally create and edit their own listings, instead of browsing a fixed set of homes."
                ),
                ReleaseHighlight(
                    icon: "map.fill",
                    title: "Friends, maps, and an invite",
                    detail: "Friend requests, a map of listings near you, and an invite flow for bringing someone new in all landed together."
                ),
                ReleaseHighlight(
                    icon: "calendar",
                    title: "Know when a place is free",
                    detail: "Hosts could block dates on a calendar, so guests stopped asking for nights that were already taken."
                )
            ]
        ),
        Release(
            version: "0.1",
            date: "July 2025 \u{2013} January 2026",
            intro: "The very first sketch of FreeBNB, before there was a backend behind it.",
            highlights: [
                ReleaseHighlight(
                    icon: "square.grid.2x2.fill",
                    title: "A feed of homes to scroll",
                    detail: "The first version of FreeBNB was a simple feed of homes to browse, each with its own photos and amenities."
                ),
                ReleaseHighlight(
                    icon: "line.3.horizontal.decrease.circle.fill",
                    title: "Filter and sort",
                    detail: "You could filter by guest count and amenities, and sort the feed however suited your trip."
                )
            ]
        )
    ]

    /// The current release, or nil if the list is somehow empty.
    static var latest: Release? { releases.first }

    /// Whether the changelog should auto-present: true when the current build is a
    /// release we have notes for and the user hasn't seen that version's notes yet.
    /// A first-ever launch (`lastSeenVersion == nil`) is treated as "already seen"
    /// so onboarding, not the changelog, greets a brand-new user.
    static func shouldPresent(currentVersion: String, lastSeenVersion: String?) -> Bool {
        guard let latest, latest.version == currentVersion else { return false }
        guard let lastSeenVersion else { return false }
        return lastSeenVersion != currentVersion
    }
}

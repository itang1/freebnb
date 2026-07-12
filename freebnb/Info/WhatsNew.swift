//
//  WhatsNew.swift
//  freebnb
//
//  The in-app changelog (feature 43). A static, hand-curated list of what shipped,
//  newest first. `WhatsNewPage` renders it, and `ContentView` auto-presents the
//  latest entry once per version bump. Keeping it here (not fetched) means the
//  changelog ships with the build it describes and needs no network or billing.
//

import Foundation

/// One shipped change within a release.
struct ReleaseHighlight: Identifiable, Hashable {
    let icon: String
    let title: String
    let detail: String
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
    /// Newest first. `latest` is the head of this list. FreeBNB has shipped exactly
    /// one release so far, so this is a single "welcome" entry rather than a running
    /// changelog; the next real version bump prepends a new `Release` here.
    static let releases: [Release] = [
        Release(
            version: "1.0",
            date: "July 2026",
            intro: "Welcome to FreeBNB, this is our very first release. FreeBNB is a place to stay with people you actually know: browse rooms and homes opened up by your friends, ask to stay, and host them back. No fees, no payments, ever. Here's everything the app can do on day one.",
            highlights: [
                ReleaseHighlight(
                    icon: "house.fill",
                    title: "Stay with friends, for free",
                    detail: "Browse spare rooms and whole homes that people in your circle have opened up, and request a stay. Money never changes hands; it's friends hosting friends."
                ),
                ReleaseHighlight(
                    icon: "message.fill",
                    title: "Message and request, all in one chat",
                    detail: "Reach out to a host and request your stay in the same conversation. They accept or decline right there, and every trip you take and guest you host lives in the Stays tab."
                ),
                ReleaseHighlight(
                    icon: "calendar",
                    title: "See everything before you go",
                    detail: "Check a host's availability, read reviews from past guests, and unlock the exact address and house manual the moment your stay is accepted."
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

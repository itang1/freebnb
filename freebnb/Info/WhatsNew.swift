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
    let highlights: [ReleaseHighlight]
    var id: String { version }
}

enum WhatsNew {
    /// Newest first. `latest` is the head of this list.
    static let releases: [Release] = [
        Release(
            version: "1.2",
            date: "July 2026",
            highlights: [
                ReleaseHighlight(
                    icon: "wifi.slash",
                    title: "Works offline",
                    detail: "A banner now tells you when you've lost connection, and messages you send are queued and delivered automatically once you're back online."
                ),
                ReleaseHighlight(
                    icon: "magnifyingglass",
                    title: "Saved places in Spotlight",
                    detail: "Search your saved listings straight from the iOS home screen. Tap a result to jump right to the listing."
                ),
                ReleaseHighlight(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Tell us what you think",
                    detail: "A new feedback composer under Info lets you send ideas, report problems, or just say hi."
                )
            ]
        ),
        Release(
            version: "1.1",
            date: "June 2026",
            highlights: [
                ReleaseHighlight(
                    icon: "calendar",
                    title: "Availability calendars",
                    detail: "Hosts can block off dates, and guests see them before they ask. Export blocked periods to your own calendar."
                ),
                ReleaseHighlight(
                    icon: "person.2",
                    title: "Co-hosts",
                    detail: "Add a friend as a co-host so they can help manage a listing without taking it over."
                ),
                ReleaseHighlight(
                    icon: "qrcode",
                    title: "QR-code invites",
                    detail: "Invite a friend by having them scan your code, no link-copying required."
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

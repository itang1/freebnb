//
//  ThemeCopy.swift
//  freebnb
//
//  The house voice: a sunny, salty, slightly goofy beach-shack host who still says plainly what's going
//  on. Themed strings live here (not scattered through views) so the voice can be tuned in one file and
//  feature work in the views doesn't collide with copy changes. Rules of the voice: lead with the plain
//  meaning, keep the pun light, never make an error or safety message cute.
//

import Foundation

enum ThemeCopy {
    // MARK: Tabs

    enum Tab {
        static let explore = "Explore"
        static let exploreIcon = "beach.umbrella.fill"
        static let trips = "Trips"
        static let tripsIcon = "sailboat.fill"
        static let messages = "Messages"
        static let messagesIcon = "bubble.left.and.bubble.right.fill"
        static let crew = "Crew"
        static let crewIcon = "person.3.fill"
        static let profile = "Profile"
        static let profileIcon = "figure.pool.swim"
    }

    // MARK: Screen titles

    enum Title {
        static let explore = "Hideaways"
        static let crew = "Your Crew"
        static let profile = "Your Cabin"
    }

    // MARK: Welcome

    enum Welcome {
        static let eyebrow = "Welcome aboard"
        static let title = "FreeBNB"
        static let tagline = "Kick off your flip-flops. Free stays with friends, from lake cabins to beach shacks."
        static let postcard = "Wish you were here!"

        static let crewTitle = "Only your crew"
        static let crewSubtitle = "No strangers, ever. Not even a stray crab."
        static let freeTitle = "Free as the breeze"
        static let freeSubtitle = "No booking fees, no surprise charges."
        static let privateTitle = "Your circle stays yours"
        static let privateSubtitle = "We never upload your contacts."
    }

    // MARK: Onboarding

    enum Onboarding {
        struct Slide {
            let icon: String
            let title: String
            let body: String
        }

        static let slides: [Slide] = [
            Slide(
                icon: "house.lodge.fill",
                title: "Your vacation starts here",
                body: "A free place to crash with friends and friends of friends. No strangers, no booking fees. Just sun, sand and good company."
            ),
            Slide(
                icon: "person.3.fill",
                title: "You'll always know your host",
                body: "You only see places from people in your network, and hosts choose who can view and request their "
                    + "space. You never request a stay from a stranger."
            ),
            Slide(
                icon: "lock.shield.fill",
                title: "Your circle stays yours",
                body: "Your network is built only from people you choose to connect with. We never scrape or upload your contacts."
            ),
            Slide(
                icon: "sailboat.fill",
                title: "Request and set sail",
                body: "Find a place and send a request with your dates. If your host says yes, grab your sunscreen and go."
            )
        ]

        static let next = "Next"
        static let skip = "Skip"
        static let hostIcon = "sofa.fill"
        static let hostTitle = "Got a couch, a cabin, or a guest room?"
        static let hostBody = "To one of your friends, that's a free getaway. Only friends you approve can ever see your place."
        static let hostAction = "List My Place"
        static let justLooking = "I'm just looking for now"
    }

    // MARK: Empty states

    enum Empty {
        static let feedNoFriendsTitle = "The beach is a little quiet"
        static let feedNoMatchesTitle = "No hideaways found"
        static let tripsTitle = "No trips on the horizon"
        static let tripsMessage = "Open a listing, message the host, and request to stay. Your trips wash up here."
        static let conversationsTitle = "No messages in the bottle yet"
        static let conversationsMessage = "Open a listing and message the host to get the conversation flowing."
        static let crewTitle = "Your crew is just you so far"
        static let crewMessage = "Search by name above to find people, or add someone from People you may know."
        static let listingsTitle = "No listings yet"
        static let listingsMessage = "Open up your lakehouse, cabin, or couch so friends have somewhere to land."
        static let listingsAction = "Create a Listing"

        static func newThread(with name: String) -> String {
            "Drop \(name) a line to get things rolling."
        }
    }

    // MARK: Status

    enum Status {
        static let offline = "No signal out here. Changes will sync when you're back in range."
        static let offlineAccessibility = "You are offline. Changes will sync when you reconnect."
        static let searchingFeed = "Combing the beach for listings…"
        static let staysLoadError = "Couldn't load your trips"
    }
}

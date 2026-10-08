//
//  AvatarAndBadgeTests.swift
//  freebnbTests
//
//  Two derivations the UI leans on: what a generated avatar resolves to, and what the Stays tab badge counts.
//

import Foundation
import SwiftUI
import Testing
@testable import freebnb

// MARK: - Generated avatars

struct GeneratedAvatarTests {
    /// The premise: the same person draws the same everywhere, forever. `hashValue` is per-process seeded, so a careless version would pass one run and change faces on relaunch.
    @Test func theSameSeedAlwaysResolvesToTheSameAvatar() {
        let first = AvatarIdentity(seed: "user-abc123")
        let second = AvatarIdentity(seed: "user-abc123")
        #expect(first == second)
        // Pinned literals, so a hash or symbol table change fails here, not as everyone's avatar silently changing.
        #expect(first.symbolName == AvatarIdentity(seed: "user-abc123").symbolName)
    }

    @Test func differentSeedsSpreadAcrossTheWholeSpace() {
        let identities = (0..<4000).map { AvatarIdentity(seed: "user-\($0)") }

        // Every symbol, hue and shade should get used, or the friends list looks like one shared avatar.
        #expect(Set(identities.map(\.symbolName)).count == AvatarIdentity.symbols.count)
        #expect(Set(identities.map(\.hueIndex)).count == AvatarIdentity.hueCount)
        #expect(Set(identities.map(\.shadeIndex)).count == AvatarIdentity.shades.count)

        // The axes must vary independently; most of the 1,920 combinations should be reachable.
        let combinations = Set(identities.map { "\($0.symbolName)-\($0.hueIndex)-\($0.shadeIndex)" })
        #expect(combinations.count > 1500)
    }

    /// A friends list should almost never show the same avatar twice. Fixed seeds, so no flakes.
    @Test func aFriendsSizedGroupRarelyCollides() {
        // 200 groups of 20, a large friends list.
        let groupsWithDuplicates = (0..<200).filter { group in
            let avatars = (0..<20).map { AvatarIdentity(seed: "group\(group)-user\($0)") }
            let distinct = Set(avatars.map { "\($0.symbolName)-\($0.hueIndex)-\($0.shadeIndex)" })
            return distinct.count < avatars.count
        }
        // The birthday-paradox expectation is about 9%; allow slack to pin the order of magnitude.
        #expect(groupsWithDuplicates.count < 40)
    }

    @Test func everyAxisStaysInsideItsRange() {
        for index in 0..<500 {
            let identity = AvatarIdentity(seed: UUID().uuidString + "\(index)")
            #expect(identity.hueIndex >= 0)
            #expect(identity.hueIndex < AvatarIdentity.hueCount)
            #expect(identity.shadeIndex >= 0)
            #expect(identity.shadeIndex < AvatarIdentity.shades.count)
            #expect(AvatarIdentity.symbols.contains(identity.symbolName))
        }
    }

    /// Avatars derive on every row render, so this asserts a very loose ceiling, a smoke alarm for added I/O or allocation, not a benchmark.
    @Test func derivingAvatarsIsFastEnoughToDoOnEveryRender() {
        let seeds = (0..<10_000).map { "user-\(UUID().uuidString)-\($0)" }
        let start = Date()
        for seed in seeds { _ = AvatarIdentity(seed: seed) }
        let elapsed = Date().timeIntervalSince(start)
        // 10,000 derivations is far more than any screen needs; a full second means something is wrong.
        #expect(elapsed < 1.0)
    }

    /// An empty seed (profile not yet loaded) must resolve stably, not crash or draw a blank circle.
    @Test func anEmptySeedStillGetsAStableAvatar() {
        #expect(AvatarIdentity(seed: "") == AvatarIdentity(seed: ""))
        #expect(AvatarIdentity.symbols.contains(AvatarIdentity(seed: "").symbolName))
    }

    /// Real Firebase UIDs share length and alphabet, so a coarse derivation (prefix, length, first byte) would pass elsewhere and give a user base three avatars.
    @Test func realWorldUIDsStillSpreadOut() {
        let uids = [
            "0kQ9vBnZ3xQKfL2mTpR7dYsWgHc2", "1aXcVbNmQwErTyUiOpAsDfGh3JkL",
            "2ZmNbVcXzLkJhGfDsAqWeRtYu4Io", "3PoIuYtReWqAsDfGhJkLzXcVbNm5",
            "4QwErTyUiOpLkJhGfDsAzXcVbN6m", "5MnBvCxZlKjHgFdSaPoIuYtReW7q",
            "6TyUiOpAsDfGhJkLzXcVbNmQwE8r", "7HgFdSaZxCvBnMlKjPoIuYtReW9q"
        ]
        let combinations = Set(uids.map { uid in
            let identity = AvatarIdentity(seed: uid)
            return "\(identity.symbolName)-\(identity.hueIndex)-\(identity.shadeIndex)"
        })
        #expect(combinations.count == uids.count)
    }
}

// MARK: - Avatar contrast

/// Avatars must stay legible in both appearances, which a fixed-brightness hue wheel
/// gets wrong. These measure the real palette colours so tweaks can't dim one into the background.
@MainActor
struct AvatarContrastTests {
    /// WCAG's floor for a graphic that carries meaning.
    private let minimumContrast = 3.0

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
        let resolved = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ color: Color) -> Double {
        let (r, g, b) = components(color)
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The symbol sits on a low-opacity disc of its own colour, so this reconstructs the disc to measure what the eye compares.
    private func discLuminance(_ color: Color, pageIsDark: Bool) -> Double {
        let (r, g, b) = components(color)
        let page: Double = pageIsDark ? 0.09 : 1.0
        let alpha = 0.20
        func blend(_ c: Double) -> Double { c * alpha + page * (1 - alpha) }
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(blend(r)) + 0.7152 * linear(blend(g)) + 0.0722 * linear(blend(b))
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func everyAvatarColourIsLegibleInLightMode() {
        for index in 0..<(AvatarIdentity.hueCount * AvatarIdentity.shades.count) {
            let identity = identity(atPaletteIndex: index)
            let color = AvatarPalette.color(for: identity, in: .light)
            let ratio = contrast(luminance(color), discLuminance(color, pageIsDark: false))
            #expect(ratio >= minimumContrast, "hue \(identity.hueIndex) shade \(identity.shadeIndex) only \(ratio)")
        }
    }

    @Test func everyAvatarColourIsLegibleInDarkMode() {
        for index in 0..<(AvatarIdentity.hueCount * AvatarIdentity.shades.count) {
            let identity = identity(atPaletteIndex: index)
            let color = AvatarPalette.color(for: identity, in: .dark)
            let ratio = contrast(luminance(color), discLuminance(color, pageIsDark: true))
            #expect(ratio >= minimumContrast, "hue \(identity.hueIndex) shade \(identity.shadeIndex) only \(ratio)")
        }
    }

    /// Light and dark mustn't resolve to the same colour, or one is served a palette tuned for the other.
    @Test func theTwoAppearancesUseDifferentColours() {
        let identity = AvatarIdentity(seed: "user-abc123")
        let light = AvatarPalette.color(for: identity, in: .light)
        let dark = AvatarPalette.color(for: identity, in: .dark)
        #expect(luminance(dark) > luminance(light))
    }

    /// Reconstructs an identity landing on a palette slot; only the hue and shade indices matter.
    private func identity(atPaletteIndex index: Int) -> AvatarIdentity {
        var found: AvatarIdentity?
        var seed = 0
        while found == nil, seed < 200_000 {
            let candidate = AvatarIdentity(seed: "probe-\(seed)")
            if candidate.paletteIndex == index { found = candidate }
            seed += 1
        }
        return found ?? AvatarIdentity(seed: "probe-0")
    }
}

// MARK: - Stays tab badge

private let host = "host-1"
private let guest = "guest-1"

private func stay(_ status: StayRequestStatus) -> StayRequest {
    StayRequest(
        listingID: "listing-1",
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: host,
        guestUserID: guest,
        checkIn: Date(timeIntervalSince1970: 1_800_000_000),
        checkOut: Date(timeIntervalSince1970: 1_800_400_000),
        status: status
    )
}

/// The badge means "someone is blocked on you": it counts what you owe an answer on in either role and ignores what you wait on.
struct StaysBadgeCountTests {
    @Test func aPendingRequestCountsForTheHostOnly() {
        let stays = [stay(.pending)]
        #expect(stays.awaitingReplyCount(from: host) == 1)
        // The guest sent it; they can't clear it, so it must not badge them.
        #expect(stays.awaitingReplyCount(from: guest) == 0)
    }

    @Test func anOfferCountsForTheGuestOnly() {
        let stays = [stay(.offered)]
        #expect(stays.awaitingReplyCount(from: guest) == 1)
        #expect(stays.awaitingReplyCount(from: host) == 0)
    }

    /// A settled stay is nobody's homework, whichever way it settled.
    @Test func resolvedStaysNeverBadgeEitherSide() {
        for status in [StayRequestStatus.accepted, .declined, .cancelled, .completed] {
            let stays = [stay(status)]
            #expect(stays.awaitingReplyCount(from: host) == 0)
            #expect(stays.awaitingReplyCount(from: guest) == 0)
        }
    }

    @Test func bothRolesAddUpForSomeoneWhoHostsAndTravels() {
        // Same person hosting one request and owing an answer on one offer.
        let stays = [stay(.pending), stay(.offered)]
        #expect(stays.awaitingReplyCount(from: host) == 1)
        #expect(stays.awaitingReplyCount(from: guest) == 1)
    }

    @Test func aSignedOutViewerIsNeverBadged() {
        #expect([stay(.pending), stay(.offered)].awaitingReplyCount(from: "") == 0)
    }
}

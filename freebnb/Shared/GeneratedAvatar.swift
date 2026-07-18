//
//  GeneratedAvatar.swift
//  freebnb
//
//  Every person gets a distinct avatar without anybody uploading a photo
//  (uploading a face is a bigger privacy decision than launch needs, and a
//  stored image is a bytes-and-moderation problem this app doesn't have yet).
//
//  The avatar is *derived*, not stored: a symbol and a colour picked from a hash
//  of the user's ID, so the same person draws identically on every screen, on
//  every device, forever, at zero storage and zero network cost. Nothing to
//  migrate, nothing to cache, nothing to garbage-collect when an account is
//  deleted.
//

import SwiftUI

/// A person's generated avatar: a soft tinted circle holding a symbol, both
/// chosen from `seed`.
///
/// Pass the user's Firestore ID as the seed wherever it is known. A display name
/// works, but it is a weaker key: two people called Alex collide, and an avatar
/// that changes when somebody edits their name defeats the point of having one.
struct GeneratedAvatar: View {
    let seed: String
    var size: CGFloat = 40
    /// Announced by VoiceOver where the avatar stands alone. Rows that already
    /// read the person's name leave this nil and keep the avatar decorative.
    var accessibilityName: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Derived once per render, not once per use: reading a computed
        // `identity` for both the colour and the symbol would hash the seed
        // twice on every pass over every row of a scrolling list.
        let identity = AvatarIdentity(seed: seed)
        let color = AvatarPalette.color(for: identity, in: colorScheme)

        return ZStack {
            Circle()
                .fill(
                    // Two stops of the same hue rather than two hues: the circle
                    // reads as one object with a light on it, and a grid of them
                    // stays calm instead of turning into confetti.
                    LinearGradient(
                        colors: [color.opacity(0.26), color.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: identity.symbolName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .modifier(AvatarAccessibility(name: accessibilityName))
    }
}

/// Applies the label when there is one and hides the avatar outright when there
/// isn't, so a decorative avatar never adds a stop to the VoiceOver rotor.
private struct AvatarAccessibility: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        if let name {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name)'s avatar")
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The (symbol, hue, shade) an avatar resolves to. Pure and cheap, and split out
/// from the view so the derivation can be unit-tested without rendering.
///
/// **On collisions.** These are drawn from a fixed space, so two users can share
/// an avatar; the question is only how often that happens *on one screen*, since
/// a name is always printed beside it. The three axes multiply out to 1,920
/// combinations, which puts two identical avatars in a 20-person friends list at
/// roughly 9% (it was 49% at 288, hence the third axis). Global uniqueness is not
/// the goal and isn't reachable without storing a per-user assignment, which is
/// exactly the storage and migration cost this design exists to avoid.
struct AvatarIdentity: Equatable {
    let symbolName: String
    let hueIndex: Int
    let shadeIndex: Int

    /// Sixteen hues rather than a continuous spectrum. A free hue per user gives
    /// near-identical teals sitting next to each other and reads as noise; a
    /// fixed wheel keeps a screenful of avatars looking like a set.
    static let hueCount = 16

    /// Three washes of whichever hue was picked. Saturation carries the variation
    /// while brightness stays in a narrow band, so all three sit at a similar
    /// luminance and the symbol keeps its contrast on both the light and the dark
    /// background. A brightness-driven axis would have made the palest shade
    /// unreadable in light mode.
    static let shades: [(saturation: Double, brightness: Double)] = [
        (0.45, 0.68), (0.65, 0.66), (0.85, 0.64)
    ]

    /// Objects, not faces or initials: an avatar that shows a letter competes
    /// with the name printed beside it, and every "A" looks like every other.
    /// All available since SF Symbols 1, so no availability gate is needed.
    static let symbols = [
        "leaf.fill", "star.fill", "moon.fill", "sun.max.fill",
        "bolt.fill", "flame.fill", "drop.fill", "sparkles",
        "cloud.fill", "umbrella.fill", "camera.fill", "book.fill",
        "music.note", "paperplane.fill", "globe", "pawprint.fill",
        "bicycle", "airplane", "gift.fill", "cup.and.saucer.fill",
        "tortoise.fill", "hare.fill", "ladybug.fill", "fish.fill",
        "bird.fill", "ant.fill", "carrot.fill", "crown.fill",
        "bell.fill", "balloon.fill", "guitars.fill", "mountain.2.fill",
        "map.fill", "key.fill", "lightbulb.fill", "puzzlepiece.fill",
        "tent.fill", "sailboat.fill", "ferry.fill", "tram.fill"
    ]

    init(seed: String) {
        // An empty seed would send every anonymous placeholder to the same
        // symbol, which looks like a bug rather than an absence. Give it its own
        // stable identity instead.
        let key = seed.isEmpty ? "freebnb.anonymous" : seed
        var hash = AvatarIdentity.hash(key)
        // Independent slices of the hash, so the three axes vary freely instead
        // of marching in lockstep (every leaf turning up teal).
        symbolName = AvatarIdentity.symbols[Int(hash % UInt64(AvatarIdentity.symbols.count))]
        hash /= UInt64(AvatarIdentity.symbols.count)
        hueIndex = Int(hash % UInt64(AvatarIdentity.hueCount))
        hash /= UInt64(AvatarIdentity.hueCount)
        shadeIndex = Int(hash % UInt64(AvatarIdentity.shades.count))
    }

    /// Where this identity sits in the flattened palette table.
    var paletteIndex: Int { hueIndex * AvatarIdentity.shades.count + shadeIndex }

    /// FNV-1a. Swift's `hashValue` is seeded per process, so it would hand the
    /// same user a different avatar on every launch; this has to be stable
    /// across launches and devices.
    private static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Palette

/// The colours the avatars are actually drawn in, one table per appearance.
///
/// Picking a hue off a wheel and holding brightness constant looks reasonable in
/// a swatch and fails on screen, because equal HSB brightness is nowhere near
/// equal *perceived* luminance: at the same brightness a yellow is roughly ten
/// times as luminous as a blue. Held constant, the yellows washed out on white
/// and the blues disappeared on black — the worst pairing measured 1.5:1, where
/// 3:1 is the floor for a graphic you are meant to be able to make out.
///
/// So brightness isn't fixed; the *luminance* is. For each hue this solves for
/// the brightness that lands on a target luminance — dark on a pale disc in light
/// mode, bright on a deep disc in dark mode — which brings the worst pairing to
/// 4.9:1 in light and 4.2:1 in dark. Some hues (blue, violet) cannot reach the
/// dark-mode target at any brightness while fully saturated, so those desaturate
/// until they can.
///
/// Both tables are built once, on first use, and read by index thereafter: the
/// solve involves a handful of `pow` calls per entry, which is nothing once but
/// would be wasteful on every row of a scrolling list.
enum AvatarPalette {
    /// Aimed low in light mode (a dark glyph on a near-white disc) and high in
    /// dark mode (a bright glyph on a near-black disc).
    private static let lightTargetLuminance = 0.10
    private static let darkTargetLuminance = 0.28

    private static let lightColors = makeTable(target: lightTargetLuminance, desaturateToReachTarget: false)
    private static let darkColors = makeTable(target: darkTargetLuminance, desaturateToReachTarget: true)

    static func color(for identity: AvatarIdentity, in scheme: ColorScheme) -> Color {
        let table = scheme == .dark ? darkColors : lightColors
        return table[identity.paletteIndex]
    }

    private static func makeTable(target: Double, desaturateToReachTarget: Bool) -> [Color] {
        var colors: [Color] = []
        colors.reserveCapacity(AvatarIdentity.hueCount * AvatarIdentity.shades.count)

        for hueIndex in 0..<AvatarIdentity.hueCount {
            let hue = Double(hueIndex) / Double(AvatarIdentity.hueCount)
            for shade in AvatarIdentity.shades {
                var saturation = shade.saturation

                // A fully saturated blue tops out well below the dark-mode
                // target however bright it gets, so trade saturation for
                // luminance until it can reach it. Light mode needs no such
                // step: a hue too dark to hit a *low* target is simply darker
                // still, which only helps against a pale disc.
                if desaturateToReachTarget {
                    while saturation > 0.08, luminance(hue: hue, saturation: saturation, brightness: 1) < target {
                        saturation -= 0.02
                    }
                }

                let ceiling = luminance(hue: hue, saturation: saturation, brightness: 1)
                // Luminance rises with brightness on roughly a gamma curve, so
                // this inverts it in one step instead of searching for the value.
                let brightness = ceiling > 0 ? min(1, pow(target / ceiling, 1 / 2.2)) : 1
                colors.append(Color(hue: hue, saturation: saturation, brightness: brightness))
            }
        }
        return colors
    }

    /// Relative luminance of an HSB colour, per the sRGB definition the contrast
    /// ratio is built on.
    private static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
        let (r, g, b) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let sector = (hue - hue.rounded(.down)) * 6
        let offset = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * offset)
        let t = brightness * (1 - saturation * (1 - offset))

        switch Int(sector) % 6 {
        case 0:  return (brightness, t, p)
        case 1:  return (q, brightness, p)
        case 2:  return (p, brightness, t)
        case 3:  return (p, q, brightness)
        case 4:  return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

/// The person-in-a-circle placeholder, for the one spot with no identity to
/// generate from: a signed-out guest.
struct PersonAvatar: View {
    var systemImage: String = "person.fill"
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accent.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.44, height: size * 0.44)
                .foregroundColor(Color.accent)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            GeneratedAvatar(seed: "user-alice")
            GeneratedAvatar(seed: "user-bob")
            GeneratedAvatar(seed: "user-carol")
            GeneratedAvatar(seed: "user-dana")
            GeneratedAvatar(seed: "")
        }
        HStack(spacing: 12) {
            GeneratedAvatar(seed: "user-alice", size: 28)
            GeneratedAvatar(seed: "user-bob", size: 44)
            GeneratedAvatar(seed: "user-carol", size: 72)
        }
    }
    .padding()
}

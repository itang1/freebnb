//
//  GeneratedAvatar.swift
//  freebnb
//
//  Every person gets a distinct avatar without uploading a photo. The avatar is
//  derived, not stored: a symbol and colour picked from a hash of the user's ID,
//  so it draws identically everywhere with no storage, migration or cleanup.
//

import SwiftUI

/// A person's generated avatar: a tinted circle holding a symbol, both chosen
/// from `seed`. Pass the user's Firestore ID where known; a display name
/// collides and changes when edited.
struct GeneratedAvatar: View {
    let seed: String
    var size: CGFloat = 40
    /// Announced by VoiceOver where the avatar stands alone; nil keeps it decorative.
    var accessibilityName: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Derived once per render rather than hashing the seed for both colour and symbol.
        let identity = AvatarIdentity(seed: seed)
        let color = AvatarPalette.color(for: identity, in: colorScheme)

        return ZStack {
            Circle()
                .fill(
                    // Two stops of one hue read as a lit object and keep a grid calm.
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

/// Applies the label if there is one, else hides the avatar from VoiceOver.
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

/// The (symbol, hue, shade) an avatar resolves to; split from the view so it's unit-testable.
///
/// Collisions: the three axes give 1,920 combinations, so two identical avatars
/// in a 20-person friends list happen roughly 9% of the time (49% at 288). A
/// name is always printed beside it, and global uniqueness would need stored assignments.
struct AvatarIdentity: Equatable {
    let symbolName: String
    let hueIndex: Int
    let shadeIndex: Int

    /// Sixteen hues, not a continuous spectrum, so a screenful reads as a set.
    static let hueCount = 16

    /// Three washes of the hue: saturation varies while brightness stays in a
    /// narrow band so the symbol keeps contrast in light and dark.
    static let shades: [(saturation: Double, brightness: Double)] = [
        (0.45, 0.68), (0.65, 0.66), (0.85, 0.64)
    ]

    /// Objects, not faces or initials, which would compete with the name beside them.
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
        // An empty seed gets its own stable identity so anonymous placeholders don't all match.
        let key = seed.isEmpty ? "freebnb.anonymous" : seed
        var hash = AvatarIdentity.hash(key)
        // Independent slices of the hash so the axes don't march in lockstep.
        symbolName = AvatarIdentity.symbols[Int(hash % UInt64(AvatarIdentity.symbols.count))]
        hash /= UInt64(AvatarIdentity.symbols.count)
        hueIndex = Int(hash % UInt64(AvatarIdentity.hueCount))
        hash /= UInt64(AvatarIdentity.hueCount)
        shadeIndex = Int(hash % UInt64(AvatarIdentity.shades.count))
    }

    /// Position in the flattened palette table.
    var paletteIndex: Int { hueIndex * AvatarIdentity.shades.count + shadeIndex }

    /// FNV-1a; Swift's `hashValue` is seeded per process and wouldn't be stable across launches.
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

/// The avatar colours, one table per appearance. Equal HSB brightness isn't
/// equal perceived luminance, so yellows washed out on white and blues vanished
/// on black (worst pairing 1.5:1). Instead each hue solves for the brightness
/// that hits a target luminance, giving worst pairings of 4.9:1 (light) and
/// 4.2:1 (dark). Hues that can't reach the dark target desaturate until they can.
/// Tables are built once on first use.
enum AvatarPalette {
    /// Aimed low in light mode (dark glyph on a pale disc) and high in dark mode.
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

                // Saturated blue can't reach the dark target at any brightness, so
                // trade saturation for luminance. Light mode needs no such step.
                if desaturateToReachTarget {
                    while saturation > 0.08, luminance(hue: hue, saturation: saturation, brightness: 1) < target {
                        saturation -= 0.02
                    }
                }

                let ceiling = luminance(hue: hue, saturation: saturation, brightness: 1)
                // Luminance rises on roughly a gamma curve; invert it in one step.
                let brightness = ceiling > 0 ? min(1, pow(target / ceiling, 1 / 2.2)) : 1
                colors.append(Color(hue: hue, saturation: saturation, brightness: brightness))
            }
        }
        return colors
    }

    /// Relative luminance of an HSB colour (sRGB definition).
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

/// The placeholder for the one spot with no identity: a signed-out guest.
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

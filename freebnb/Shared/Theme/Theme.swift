//
//  Theme.swift
//  freebnb
//
//  The "lagoon lakehouse" design tokens beyond colour: type, shape, elevation and the UIKit chrome
//  (navigation and tab bars) that SwiftUI can't style directly. Colours live in `AppColor`, motifs in
//  `Motifs.swift`, ambient motion in `ThemeMotion.swift`, and the house voice in `ThemeCopy.swift`, so
//  retuning the vacation feel never means hunting through screens.
//

import SwiftUI
import UIKit

enum Theme {
    // MARK: Shape

    enum Radius {
        /// Listing cards and other big tappable surfaces: soft as a pebble.
        static let card: CGFloat = 22
        /// Buttons, fields and banners.
        static let control: CGFloat = 16
        /// Message bubbles; the corner nearest the sender is pinched to `bubbleTail`.
        static let bubble: CGFloat = 18
        static let bubbleTail: CGFloat = 6
    }

    // MARK: Elevation

    enum Shadow {
        /// Cards cast a warm, sandy shadow rather than a grey one, like something resting on the beach.
        static let cardColor = Color.driftwood.opacity(0.22)
        static let cardRadius: CGFloat = 10
        static let cardYOffset: CGFloat = 6
    }

    // MARK: Chrome

    /// Styles navigation and tab bars to match the palette and type. Call once at launch, before any bar
    /// is created. Fonts come from the current Dynamic Type size via `roundedUIFont`.
    @MainActor
    static func configureChrome() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = .primaryBackground
        navigation.shadowColor = UIColor.driftwood.withAlphaComponent(0.25)
        navigation.largeTitleTextAttributes = [
            .font: roundedUIFont(.largeTitle, weight: .heavy),
            .foregroundColor: UIColor.accent
        ]
        navigation.titleTextAttributes = [
            .font: roundedUIFont(.headline, weight: .bold),
            .foregroundColor: UIColor.label
        ]

        // At rest over the page, the bar melts into the sand; it gains its plank-line edge once content
        // scrolls beneath it.
        let navigationAtEdge = navigation.copy()
        navigationAtEdge.shadowColor = .clear

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = navigation
        navigationBar.compactAppearance = navigation
        navigationBar.scrollEdgeAppearance = navigationAtEdge

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = .primaryBackground
        tabs.shadowColor = UIColor.driftwood.withAlphaComponent(0.3)
        let itemFont = roundedUIFont(.caption2, weight: .bold)
        for layout in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            layout.normal.iconColor = .secondaryText
            layout.normal.titleTextAttributes = [.font: itemFont, .foregroundColor: UIColor.secondaryText]
            layout.selected.iconColor = .accent
            layout.selected.titleTextAttributes = [.font: itemFont, .foregroundColor: UIColor.accent]
        }
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tabs
        tabBar.scrollEdgeAppearance = tabs
    }

    /// The system font in its rounded design at a text style's current Dynamic Type size.
    static func roundedUIFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: rounded, size: size)
    }
}

// MARK: - Type

/// Two voices: a chunky rounded display face for headlines (beach-shack signage), and a serif italic
/// "postcard" voice for asides. Body text inherits the rounded design from the app root. All of these
/// are text-style based, so they scale with Dynamic Type.
extension Font {
    /// Headlines and screen heroes.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded, weight: .heavy)
    }

    /// Short handwritten-feeling asides: taglines, "wish you were here" notes.
    static func postcard(_ style: Font.TextStyle = .subheadline) -> Font {
        .system(style, design: .serif).italic()
    }

    /// Small painted-sign labels, set in caps by `signLabel()`.
    static let sign: Font = .system(.caption, design: .rounded, weight: .heavy)
}

extension View {
    /// Applies the app's rounded type design to everything below; set once at the root.
    func themedTypography() -> some View {
        fontDesign(.rounded)
    }

    /// A painted-sign caption: heavy rounded caps with a little letter spacing.
    func signLabel() -> some View {
        font(.sign)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    /// The resting shadow for cards.
    func cardShadow() -> some View {
        shadow(color: Theme.Shadow.cardColor, radius: Theme.Shadow.cardRadius, x: 0, y: Theme.Shadow.cardYOffset)
    }
}

// MARK: - Buttons

/// The primary action: a chunky capsule with a darker "lip" underneath, like a pool toy you want to press.
/// Pressing sinks it onto its lip; under Reduce Motion it dims instead.
struct LagoonButtonStyle: ButtonStyle {
    enum Kind {
        /// Lagoon teal, for the main action of a screen.
        case primary
        /// Reef coral, for the one big "go" moment (request a stay, list my place).
        case callToAction
    }

    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        LagoonButtonLabel(configuration: configuration, kind: kind)
    }

    private struct LagoonButtonLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        private let lip: CGFloat = 4

        private var fill: Color { kind == .primary ? .accent : .callToAction }

        var body: some View {
            let sunk = configuration.isPressed && !reduceMotion
            configuration.label
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(minHeight: 44)
                .background(Capsule().fill(fill))
                .offset(y: sunk ? lip : 0)
                .background(
                    // The lip: the same capsule in a darker shade, peeking out below.
                    Capsule()
                        .fill(fill)
                        .overlay(Capsule().fill(Color.black.opacity(0.25)))
                        .offset(y: lip)
                )
                .padding(.bottom, lip)
                .opacity(isEnabled ? (reduceMotion && configuration.isPressed ? 0.75 : 1) : 0.45)
                .animation(AppAnimation.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == LagoonButtonStyle {
    /// Lagoon-teal primary action.
    static var lagoon: LagoonButtonStyle { LagoonButtonStyle() }

    /// Reef-coral call to action.
    static var lagoonCallToAction: LagoonButtonStyle { LagoonButtonStyle(kind: .callToAction) }
}

#Preview {
    VStack(spacing: 20) {
        Text("Ahoy there").font(.display())
        Text("Wish you were here.").font(.postcard())
        Text("Low tide").signLabel()
        Button("Find a hideaway") {}.buttonStyle(.lagoon)
        Button("Request a Stay") {}.buttonStyle(.lagoonCallToAction)
    }
    .padding()
    .themedTypography()
    .background(Color.primaryBackground)
}

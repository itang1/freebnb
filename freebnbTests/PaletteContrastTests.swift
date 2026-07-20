//
//  PaletteContrastTests.swift
//  freebnbTests
//
//  Measures the real contrast of every (text role, surface) pair the app puts
//  on screen, in both appearances, the same way AvatarContrastTests guards the
//  generated avatars: resolve the actual colours and compute the WCAG ratio,
//  so a palette tweak that dims text below the floor fails here instead of on
//  someone's phone.
//
//  The palette was solved for these floors by targeting a relative luminance
//  per appearance (not an HSB brightness — equal brightness is nowhere near
//  equal perceived luminance; see GeneratedAvatar's palette notes).
//

import SwiftUI
import Testing
import UIKit
@testable import freebnb

@MainActor
struct PaletteContrastTests {
    /// WCAG floors: 4.5:1 for text, 3:1 for meaningful non-text graphics.
    private let textFloor = 4.5
    private let graphicFloor = 3.0

    private func resolved(_ role: AppColor, dark: Bool) -> UIColor {
        UIColor.app(role).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        )
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fill` composited over `base` at `alpha` — what a soft chip actually
    /// shows behind its text.
    private func blended(_ fill: UIColor, over base: UIColor, alpha: CGFloat) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        fill.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: fr * alpha + br * (1 - alpha),
            green: fg * alpha + bg * (1 - alpha),
            blue: fb * alpha + bb * (1 - alpha),
            alpha: 1
        )
    }

    /// A plain list row's own background, which `scrollContentBackground(.hidden)`
    /// does not restyle — status text in the Stays list sits on this, not on the
    /// app's own washes.
    private func systemRow(dark: Bool) -> UIColor {
        UIColor.secondarySystemGroupedBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        )
    }

    /// Every text role on every surface it is actually used over.
    private let textPairs: [(fg: AppColor, bg: AppColor)] = [
        (.accent, .primaryBackground),
        (.accent, .secondaryBackground),
        (.accent, .tertiaryBackground),
        (.callToAction, .primaryBackground),
        (.onAccent, .accent),
        (.onAccent, .callToAction),
        (.success, .primaryBackground),
        (.danger, .primaryBackground),
        (.warning, .primaryBackground),
        (.secondaryText, .primaryBackground),
        (.secondaryText, .secondaryBackground),
        (.secondaryText, .tertiaryBackground),
    ]

    /// Status roles also live in plain list rows and on their own soft fills.
    private let statusRoles: [AppColor] = [.success, .danger, .warning, .accent, .callToAction, .secondaryText]

    @Test(arguments: [false, true])
    func everyTextRoleReadsOnItsSurfaces(dark: Bool) {
        for pair in textPairs {
            let ratio = contrast(resolved(pair.fg, dark: dark), resolved(pair.bg, dark: dark))
            #expect(ratio >= textFloor, "\(pair.fg) on \(pair.bg) (\(dark ? "dark" : "light")) is only \(ratio)")
        }
    }

    @Test(arguments: [false, true])
    func statusTextReadsOnAPlainListRow(dark: Bool) {
        for role in statusRoles {
            let ratio = contrast(resolved(role, dark: dark), systemRow(dark: dark))
            #expect(ratio >= textFloor, "\(role) on a list row (\(dark ? "dark" : "light")) is only \(ratio)")
        }
    }

    /// StatusBadge and the banners tint their text's own colour to 15% for the
    /// fill behind it; the text has to survive its own chip.
    @Test(arguments: [false, true])
    func statusTextSurvivesItsOwnSoftFill(dark: Bool) {
        for role in [AppColor.success, .danger, .warning] {
            let text = resolved(role, dark: dark)
            let fill = blended(text, over: systemRow(dark: dark), alpha: 0.15)
            let ratio = contrast(text, fill)
            #expect(ratio >= textFloor, "\(role) on its own 15% fill (\(dark ? "dark" : "light")) is only \(ratio)")
        }
    }

    /// The unread dot (coral on a row) and other meaningful non-text marks.
    @Test(arguments: [false, true])
    func meaningfulGraphicsClearTheirFloor(dark: Bool) {
        let dot = contrast(resolved(.callToAction, dark: dark), systemRow(dark: dark))
        #expect(dot >= graphicFloor, "unread dot on a row (\(dark ? "dark" : "light")) is only \(dot)")
    }
}

//
//  AppColor.swift
//  freebnb
//

import SwiftUI
import UIKit

/// Semantic roles for the "lakeside summer" palette. Raw values are asset-catalog
/// paths under `Color/`, so each role resolves light and dark dynamically. Views
/// reference roles, never hues, so the palette retunes without touching call sites.
enum AppColor: String, CaseIterable {
    /// Deep lake teal. Primary brand color: tints, buttons, chips, links.
    case accent = "Color/accent"

    /// Seafoam. Secondary water tone for subtle fills and illustrations.
    case secondaryAccent = "Color/secondaryAccent"

    /// Sunset coral. High-emphasis calls to action ("Request stay").
    case callToAction = "Color/callToAction"

    /// Warm sand. App-wide page and sheet background.
    case primaryBackground = "Color/primaryBackground"

    /// Sky blue. Card and grouped-content washes over the primary background.
    case secondaryBackground = "Color/secondaryBackground"

    /// Shell pink. Soft blush fills for badges and highlights.
    case tertiaryBackground = "Color/tertiaryBackground"

    /// Pine sage. Positive states and greenery accents.
    case success = "Color/success"

    /// Failures and destructive actions; replaces system `.red` (3.2:1 on sand in light mode).
    case danger = "Color/danger"

    /// Cautions the user can proceed past; replaces system `.orange` (2.0:1 on sand).
    case warning = "Color/warning"

    /// Supporting text; replaces system `.secondary`, which never reaches 4.5:1 (2.6:1 on the sky-blue wash).
    case secondaryText = "Color/secondaryText"

    /// Text and icons placed on `accent` or `callToAction` fills.
    case onAccent = "Color/onAccent"
}

// MARK: - SwiftUI

extension Color {
    init(_ role: AppColor) {
        self.init(role.rawValue)
    }

    static let accent = Color(AppColor.accent)
    static let secondaryAccent = Color(AppColor.secondaryAccent)
    static let callToAction = Color(AppColor.callToAction)
    static let primaryBackground = Color(AppColor.primaryBackground)
    static let secondaryBackground = Color(AppColor.secondaryBackground)
    static let tertiaryBackground = Color(AppColor.tertiaryBackground)
    static let success = Color(AppColor.success)
    static let danger = Color(AppColor.danger)
    static let warning = Color(AppColor.warning)
    static let secondaryText = Color(AppColor.secondaryText)
    static let onAccent = Color(AppColor.onAccent)
}

/// Makes roles available as implicit members wherever SwiftUI expects a `ShapeStyle`, e.g.
/// `.foregroundStyle(.accent)`.
extension ShapeStyle where Self == Color {
    static var accent: Color { Color(AppColor.accent) }
    static var secondaryAccent: Color { Color(AppColor.secondaryAccent) }
    static var callToAction: Color { Color(AppColor.callToAction) }
    static var primaryBackground: Color { Color(AppColor.primaryBackground) }
    static var secondaryBackground: Color { Color(AppColor.secondaryBackground) }
    static var tertiaryBackground: Color { Color(AppColor.tertiaryBackground) }
    static var success: Color { Color(AppColor.success) }
    static var danger: Color { Color(AppColor.danger) }
    static var warning: Color { Color(AppColor.warning) }
    static var secondaryText: Color { Color(AppColor.secondaryText) }
    static var onAccent: Color { Color(AppColor.onAccent) }
}

// MARK: - UIKit

extension UIColor {
    /// Resolves a role from the asset catalog; a miss means a deleted or renamed asset, so fail loudly in debug.
    static func app(_ role: AppColor) -> UIColor {
        guard let color = UIColor(named: role.rawValue) else {
            assertionFailure("Missing colorset for \(role.rawValue) in Assets.xcassets")
            return .systemPink
        }
        return color
    }

    static let accent = UIColor.app(.accent)
    static let secondaryAccent = UIColor.app(.secondaryAccent)
    static let callToAction = UIColor.app(.callToAction)
    static let primaryBackground = UIColor.app(.primaryBackground)
    static let secondaryBackground = UIColor.app(.secondaryBackground)
    static let tertiaryBackground = UIColor.app(.tertiaryBackground)
    static let success = UIColor.app(.success)
    static let danger = UIColor.app(.danger)
    static let warning = UIColor.app(.warning)
    static let secondaryText = UIColor.app(.secondaryText)
    static let onAccent = UIColor.app(.onAccent)
}

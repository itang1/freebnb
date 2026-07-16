//
//  AppColor.swift
//  freebnb
//

import SwiftUI
import UIKit

/// Semantic roles for the "lakeside summer" palette.
///
/// Raw values are asset-catalog paths inside the `Color/` namespace of
/// Assets.xcassets, so every role resolves its light and dark variant
/// dynamically. Views reference roles (`.accent`, `.primaryBackground`),
/// never hues; the palette can be retuned in the catalog without touching
/// call sites.
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
    static let onAccent = Color(AppColor.onAccent)
}

/// Makes roles available as implicit members wherever SwiftUI expects a
/// `ShapeStyle` rather than a `Color`, e.g. `.background(.primaryBackground)`
/// or `.foregroundStyle(.accent)`.
extension ShapeStyle where Self == Color {
    static var accent: Color { Color(AppColor.accent) }
    static var secondaryAccent: Color { Color(AppColor.secondaryAccent) }
    static var callToAction: Color { Color(AppColor.callToAction) }
    static var primaryBackground: Color { Color(AppColor.primaryBackground) }
    static var secondaryBackground: Color { Color(AppColor.secondaryBackground) }
    static var tertiaryBackground: Color { Color(AppColor.tertiaryBackground) }
    static var success: Color { Color(AppColor.success) }
    static var onAccent: Color { Color(AppColor.onAccent) }
}

// MARK: - UIKit

extension UIColor {
    /// Resolves a semantic role from the asset catalog. The colorsets ship in
    /// the app bundle, so a miss can only mean a deleted or renamed asset;
    /// fail loudly in debug builds rather than force-unwrapping.
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
    static let onAccent = UIColor.app(.onAccent)
}

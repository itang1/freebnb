//
//  WidgetPalette.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The widget extension can't reach the asset catalog, so the brand accent is defined in code (matching
//  Assets.xcassets/Color/accent.colorset) and adapts to light/dark; shared with the Live Activity.
//

import SwiftUI
import UIKit

enum WidgetPalette {
    /// The teal brand accent: 0A6774 light, 5CC1CD dark, as the app's `accent` colour set.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x5C / 255, green: 0xC1 / 255, blue: 0xCD / 255, alpha: 1)
            : UIColor(red: 0x0A / 255, green: 0x67 / 255, blue: 0x74 / 255, alpha: 1)
    })
}

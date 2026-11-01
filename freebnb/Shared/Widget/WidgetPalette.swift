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
    /// The lagoon-teal brand accent: 006A78 light, 52D0D6 dark, as the app's `accent` colour set.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x52 / 255, green: 0xD0 / 255, blue: 0xD6 / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x6A / 255, blue: 0x78 / 255, alpha: 1)
    })
}

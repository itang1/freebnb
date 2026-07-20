//
//  WidgetPalette.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The widget extension can't reach the app's asset catalog, so the brand accent
//  is defined in code here (matching Assets.xcassets/Color/accent.colorset) and
//  adapts to light/dark itself. Shared so the Live Activity, which the app also
//  renders into, uses the identical colour.
//

import SwiftUI
import UIKit

enum WidgetPalette {
    /// The teal brand accent: 0A6774 in light, 5CC1CD in dark — the same values
    /// as the app's `accent` colour set.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x5C / 255, green: 0xC1 / 255, blue: 0xCD / 255, alpha: 1)
            : UIColor(red: 0x0A / 255, green: 0x67 / 255, blue: 0x74 / 255, alpha: 1)
    })
}

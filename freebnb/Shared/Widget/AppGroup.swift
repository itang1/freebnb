//
//  AppGroup.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The one place the App Group identifier is written down. Both the app (which
//  writes the widget snapshot) and the widget extension (which reads it) resolve
//  their shared UserDefaults suite through here, so a typo can't silently split
//  them onto two different containers.
//

import Foundation

enum WidgetAppGroup {
    /// Must match the App Group capability enabled on *both* the app target and
    /// the widget extension target in Xcode (see the setup checklist).
    static let identifier = "group.com.poodlestrategy.freebnb"

    /// The shared defaults suite, or nil if the App Group entitlement is missing
    /// (e.g. running before the capability is wired up). Callers treat nil as
    /// "no data available" rather than crashing.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

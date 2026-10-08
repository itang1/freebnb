//
//  AppGroup.swift
//  freebnb (shared with the freebnbWidgets extension)
//
//  The one place the App Group identifier is written, so the app and widget extension resolve the same shared UserDefaults suite.
//

import Foundation

enum WidgetAppGroup {
    /// Must match the App Group capability on both the app and widget extension targets.
    static let identifier = "group.com.poodlestrategy.freebnb"

    /// The shared defaults suite, or nil if the entitlement is missing; callers treat nil as "no data", not a crash.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

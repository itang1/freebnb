//
//  Telemetry.swift
//  freebnb
//
//  The app's single observability seam: crash reporting, funnel analytics and a
//  decode-failure counter, as no-op-safe static wrappers so the app never imports the
//  Firebase SDKs directly. Collection is suppressed for the emulator and UI tests;
//  `configure()` only flips collection on or off.
//

import FirebaseAnalytics
import FirebaseCrashlytics
import Foundation
import os

enum Telemetry {
    private static let log = AppLog.logger("telemetry")

    /// Key product funnels. Raw values are Analytics event names; keep them snake_case and stable (renaming resets the funnel).
    enum Event: String {
        case signInCompleted = "sign_in_completed"
        case signInFailed = "sign_in_failed"
        case createListingCompleted = "create_listing_completed"
        case stayRequestSent = "stay_request_sent"
        /// A host offering unprompted. Counted apart from `stayRequestSent` so whether hosts start anything is visible.
        case stayOfferSent = "stay_offer_sent"
        case stayRequestAccepted = "stay_request_accepted"
    }

    /// Whether telemetry is delivered. Emulator and UI-test runs are excluded; mirrors `EmulatorEnvironment`.
    private static var isCollectionEnabled: Bool {
        if EmulatorEnvironment.isActive { return false }
        if ProcessInfo.processInfo.arguments.contains("-UITesting") { return false }
        return true
    }

    /// Called once at launch after `FirebaseApp.configure()`; only toggles collection.
    static func configure() {
        let enabled = isCollectionEnabled
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
        Analytics.setAnalyticsCollectionEnabled(enabled)
        if !enabled { log.debug("Telemetry collection disabled (emulator/UI test).") }
    }

    /// Ties crash reports and analytics to the signed-in user; nil on sign-out (Crashlytics has no "clear", so "" stands in).
    static func setUserID(_ userID: String?) {
        Crashlytics.crashlytics().setUserID(userID ?? "")
        Analytics.setUserID(userID)
    }

    /// Logs a key funnel event.
    static func log(_ event: Event, parameters: [String: Any]? = nil) {
        Analytics.logEvent(event.rawValue, parameters: parameters)
    }

    /// Records a swallowed error as a Crashlytics non-fatal so hidden failures become visible.
    static func recordError(_ error: Error, context: String) {
        log.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Crashlytics.crashlytics().log(context)
        Crashlytics.crashlytics().record(error: error)
    }

    /// Counts a Firestore document that failed to decode. Repositories compactMap
    /// failures to nil, so a corrupt document would vanish; each drop becomes an Analytics
    /// event (by collection) plus a breadcrumb. Kept off `record(error:)` so a corrupt doc doesn't flood non-fatals.
    static func decodeFailure(collection: String, documentID: String, error: Error) {
        decodeFailure(collection: collection, documentID: documentID, reason: error.localizedDescription)
    }

    /// The same for failable-initializer decoders that carry only a reason, no `Error`.
    static func decodeFailure(collection: String, documentID: String, reason: String = "malformed") {
        log.error("decode \(collection, privacy: .public)/\(documentID, privacy: .public): \(reason, privacy: .public)")
        Analytics.logEvent("decode_failure", parameters: ["collection": collection])
        Crashlytics.crashlytics().log("decode failure \(collection)/\(documentID): \(reason)")
    }
}

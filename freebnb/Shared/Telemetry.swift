//
//  Telemetry.swift
//  freebnb
//
//  The app's single observability seam (A6): crash reporting, key-funnel
//  analytics, and a decode-failure counter (A5). Every entry point is a
//  no-op-safe static wrapper, so the rest of the app never imports the Firebase
//  observability SDKs directly and callers never branch on availability.
//
//  Collection is suppressed when the process is pointed at the emulator or is a
//  UI-test run, so automated and local sessions never ship telemetry to a real
//  project. Firebase auto-initialises Crashlytics, Analytics, and Performance
//  Monitoring at FirebaseApp.configure(); `configure()` below only flips
//  collection on or off.
//

import FirebaseAnalytics
import FirebaseCrashlytics
import Foundation
import os

enum Telemetry {
    private static let log = AppLog.logger("telemetry")

    /// Key product funnels worth measuring (A6). Raw values are the Analytics
    /// event names: keep them snake_case and stable, since renaming one resets
    /// its funnel in the console.
    enum Event: String {
        case signInCompleted = "sign_in_completed"
        case signInFailed = "sign_in_failed"
        case createListingCompleted = "create_listing_completed"
        case stayRequestSent = "stay_request_sent"
        case stayRequestAccepted = "stay_request_accepted"
    }

    /// Whether telemetry should actually be delivered. Emulator and UI-test runs
    /// are excluded so they never pollute production dashboards; this mirrors the
    /// detection in `EmulatorEnvironment`.
    private static var isCollectionEnabled: Bool {
        if EmulatorEnvironment.isActive { return false }
        if ProcessInfo.processInfo.arguments.contains("-UITesting") { return false }
        return true
    }

    /// Called once at launch, right after `FirebaseApp.configure()`. Only toggles
    /// collection; the SDKs initialise themselves.
    static func configure() {
        let enabled = isCollectionEnabled
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
        Analytics.setAnalyticsCollectionEnabled(enabled)
        if !enabled { log.debug("Telemetry collection disabled (emulator/UI test).") }
    }

    /// Ties crash reports and analytics to the signed-in user; pass nil on
    /// sign-out. Crashlytics has no "clear", so an empty string stands in.
    static func setUserID(_ userID: String?) {
        Crashlytics.crashlytics().setUserID(userID ?? "")
        Analytics.setUserID(userID)
    }

    /// Logs a key funnel event.
    static func log(_ event: Event, parameters: [String: Any]? = nil) {
        Analytics.logEvent(event.rawValue, parameters: parameters)
    }

    /// Records a swallowed error as a Crashlytics non-fatal with a breadcrumb,
    /// so failures the UI hides become visible in the field.
    static func recordError(_ error: Error, context: String) {
        log.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Crashlytics.crashlytics().log(context)
        Crashlytics.crashlytics().record(error: error)
    }

    /// Counts a Firestore document that failed to decode (A5). Repositories
    /// compactMap failed decodes to nil, so without this a corrupt document
    /// vanishes silently; here each drop is an Analytics event (partitioned by
    /// collection) plus a Crashlytics breadcrumb, so the decode-failure rate is
    /// measurable. Kept off `record(error:)` deliberately: one corrupt doc read
    /// on every snapshot would flood non-fatals.
    static func decodeFailure(collection: String, documentID: String, error: Error) {
        decodeFailure(collection: collection, documentID: documentID, reason: error.localizedDescription)
    }

    /// Same as above for the failable-initializer decoders that parse a document
    /// by hand and so carry no `Error` to report, only a reason.
    static func decodeFailure(collection: String, documentID: String, reason: String = "malformed") {
        log.error("decode \(collection, privacy: .public)/\(documentID, privacy: .public): \(reason, privacy: .public)")
        Analytics.logEvent("decode_failure", parameters: ["collection": collection])
        Crashlytics.crashlytics().log("decode failure \(collection)/\(documentID): \(reason)")
    }
}

//
//  StayReminderScheduler.swift
//  freebnb
//
//  Pre-check-in and pre-checkout reminders (feature 22). These are *local*
//  notifications scheduled on device from the accepted stays the app already
//  syncs, so they need no server, no push token, and no Blaze billing — they
//  fire even offline. The scheduling decisions (which reminders, when, with what
//  copy) live in a pure `StayReminder.reminders(for:...)` so they can be
//  unit-tested without touching UNUserNotificationCenter.
//

import Foundation
import UserNotifications
import os

/// One local notification to schedule for a confirmed stay.
struct StayReminder: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The evening before check-in.
        case checkIn
        /// The morning of checkout.
        case checkOut
    }

    let stayID: String
    let kind: Kind
    let fireDate: Date
    let title: String
    let body: String

    /// Stable per (stay, kind), so re-scheduling replaces rather than duplicates,
    /// and the `stay-` prefix lets the scheduler prune only its own reminders.
    var identifier: String { "stay-\(kind.rawValue)-\(stayID)" }
}

extension StayReminder {
    /// Hour of day (local) each reminder fires at. Check-in the evening before so
    /// there's time to pack; checkout the morning of, before the day gets away.
    static let checkInHour = 18
    static let checkOutHour = 9

    /// The reminders to schedule for `stays`, from `viewerID`'s point of view.
    /// Only accepted stays with a fire date still in the future are included, so
    /// a stay whose check-in already passed schedules only its checkout reminder,
    /// and a finished-but-not-yet-swept stay schedules nothing.
    static func reminders(
        for stays: [StayRequest],
        viewerID: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [StayReminder] {
        stays
            .filter { $0.status == .accepted }
            .flatMap { stay -> [StayReminder] in
                let isHost = stay.role(of: viewerID) == .host
                let city = stay.listingCity
                var out: [StayReminder] = []

                if let dayBefore = calendar.date(byAdding: .day, value: -1, to: stay.checkIn),
                   let fire = calendar.date(bySettingHour: checkInHour, minute: 0, second: 0, of: dayBefore),
                   fire > now {
                    out.append(StayReminder(
                        stayID: stay.id,
                        kind: .checkIn,
                        fireDate: fire,
                        title: isHost ? "A guest arrives tomorrow" : "Check-in is tomorrow",
                        body: isHost
                            ? "Your guest checks in tomorrow at \(city). A good time to sort out the key handoff."
                            : "You check in tomorrow at \(city). Your host will appreciate a heads-up on your arrival time."
                    ))
                }

                if let fire = calendar.date(bySettingHour: checkOutHour, minute: 0, second: 0, of: stay.checkOut),
                   fire > now {
                    out.append(StayReminder(
                        stayID: stay.id,
                        kind: .checkOut,
                        fireDate: fire,
                        title: isHost ? "A stay ends today" : "Checkout is today",
                        body: isHost
                            ? "Your guest checks out of \(city) today."
                            : "Your stay at \(city) ends today. Once you're out, a review is a nice way to say thanks."
                    ))
                }

                return out
            }
    }
}

/// Reconciles the on-device notification schedule with the current set of
/// accepted stays. `@MainActor` because UNUserNotificationCenter is main-actor
/// friendliest here and the caller is a `@MainActor` store; the work inside is
/// all async so nothing blocks the main thread.
@MainActor
final class StayReminderScheduler {
    private let center: UNUserNotificationCenter
    private let log = AppLog.logger("reminders")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Makes the scheduled reminders match `stays` exactly: schedules the ones
    /// that should exist, and cancels any previously-scheduled stay reminder that
    /// no longer should (a stay was cancelled, completed, or had its dates moved).
    /// Only reminders this type owns (the `stay-` prefix) are ever removed.
    func sync(acceptedStays stays: [StayRequest], viewerID: String, now: Date = Date()) async {
        guard !viewerID.isEmpty else { return }
        let desired = StayReminder.reminders(for: stays, viewerID: viewerID, now: now)
        let desiredIDs = Set(desired.map(\.identifier))

        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("stay-") && !desiredIDs.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for reminder in desired {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.userInfo = ["type": "stay_reminder", "stayID": reminder.stayID]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: reminder.identifier,
                content: content,
                trigger: trigger
            )
            do {
                // Re-adding an existing identifier replaces it, which is exactly
                // what we want when a stay's dates change.
                try await center.add(request)
            } catch {
                log.error("failed to schedule \(reminder.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

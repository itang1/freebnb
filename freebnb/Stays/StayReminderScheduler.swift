//
//  StayReminderScheduler.swift
//  freebnb
//
//  Pre-check-in and pre-checkout reminders: local notifications scheduled from the accepted
//  stays the app syncs, so they need no server or push token and fire offline. The decisions
//  live in a pure `StayReminder.reminders(for:...)`, unit-tested without UNUserNotificationCenter.
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

    /// Stable per (stay, kind), so rescheduling replaces; the `stay-` prefix lets the scheduler prune only its own.
    var identifier: String { "stay-\(kind.rawValue)-\(stayID)" }
}

extension StayReminder {
    /// Local hour each fires: check-in the evening before (time to pack), checkout that morning.
    static let checkInHour = 18
    static let checkOutHour = 9

    /// The reminders for `stays` from `viewerID`'s view: accepted stays with a future fire date only,
    /// so a started stay schedules just checkout and a finished-but-unswept one nothing.
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
                            ? "Your guest checks in tomorrow in \(city). A good time to sort out the key handoff."
                            : "You check in tomorrow in \(city). A good time to let your host know when you'll arrive."
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
                            : "Your stay in \(city) ends today. Once you're out, you can leave your host a review."
                    ))
                }

                return out
            }
    }
}

/// Reconciles on-device notifications with the current accepted stays. `@MainActor`
/// for its main-actor store caller; the work is async so nothing blocks the main thread.
@MainActor
final class StayReminderScheduler {
    private let center: UNUserNotificationCenter
    private let log = AppLog.logger("reminders")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Makes the scheduled reminders match `stays` exactly, scheduling those that should
    /// exist and cancelling stale ones (cancelled, completed or moved). Only the `stay-` prefix is removed.
    func sync(acceptedStays stays: [StayRequest], viewerID: String, now: Date = Date()) async {
        // Signed out: nothing desired, which cancels every reminder this type owns. Returning early would leave
        // the departed user's "You check in tomorrow in Lisbon" on the next person's Lock Screen.
        let desired = viewerID.isEmpty
            ? []
            : StayReminder.reminders(for: stays, viewerID: viewerID, now: now)
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
                // Re-adding an identifier replaces it, which handles moved dates.
                try await center.add(request)
            } catch {
                log.error("failed to schedule \(reminder.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

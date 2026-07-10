//
//  CalendarInvite.swift
//  freebnb
//
//  Builds a shareable .ics file for a confirmed stay so a guest can add it to
//  their calendar from the share sheet — no EventKit permission or entitlement
//  required, which keeps the "add to Calendar" button on the logistics card
//  friction-free (feature 19).
//

import Foundation

enum CalendarInvite {
    /// One all-day VEVENT. `endDay` is the exclusive bound — the departure day for
    /// a stay, the day after the last blocked night for an availability block —
    /// which is exactly what iCalendar's DTEND means for an all-day event.
    struct Event {
        var uid: String
        var title: String
        var location: String?
        var notes: String?
        var startDay: Date
        var endDay: Date
    }

    /// Writes a single all-day VEVENT to a temporary .ics file and returns its URL.
    /// Returns nil if the file can't be written.
    static func icsFile(
        uid: String,
        title: String,
        location: String?,
        notes: String?,
        startDay: Date,
        endDay: Date
    ) -> URL? {
        icsFile(
            events: [Event(uid: uid, title: title, location: location, notes: notes, startDay: startDay, endDay: endDay)],
            filename: "FreeBNB-Stay.ics"
        )
    }

    /// Writes any number of all-day VEVENTs into one calendar file — a host's
    /// blocked periods (feature 16), or a single stay. Returns nil for an empty
    /// event list, since a calendar with nothing in it is not worth sharing.
    ///
    /// `filename` distinguishes the exports in the temporary directory; two
    /// features writing to one path would let a stale stay ride out under an
    /// availability export's name.
    static func icsFile(events: [Event], filename: String) -> URL? {
        guard !events.isEmpty else { return nil }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//FreeBNB//Stays//EN",
            "CALSCALE:GREGORIAN"
        ]
        let stamp = timestamp(Date())
        for event in events {
            lines.append(contentsOf: [
                "BEGIN:VEVENT",
                "UID:\(event.uid)@freebnb.app",
                "DTSTAMP:\(stamp)",
                "DTSTART;VALUE=DATE:\(day(event.startDay))",
                "DTEND;VALUE=DATE:\(day(event.endDay))",
                "SUMMARY:\(escape(event.title))"
            ])
            if let location = event.location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
            if let notes = event.notes, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")

        // iCalendar requires CRLF line endings.
        let ics = lines.joined(separator: "\r\n") + "\r\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try ics.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func timestamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    /// Escapes the characters iCalendar reserves in TEXT values.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

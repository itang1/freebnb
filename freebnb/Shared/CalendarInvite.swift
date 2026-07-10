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
    /// Writes a single all-day VEVENT spanning `startDay`…`endDay` to a temporary
    /// .ics file and returns its URL. `endDay` is treated as the departure day:
    /// iCalendar's DTEND is exclusive for all-day events, so a checkout date maps
    /// to it directly. Returns nil if the file can't be written.
    static func icsFile(
        uid: String,
        title: String,
        location: String?,
        notes: String?,
        startDay: Date,
        endDay: Date
    ) -> URL? {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//FreeBNB//Stays//EN",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(uid)@freebnb.app",
            "DTSTAMP:\(timestamp(Date()))",
            "DTSTART;VALUE=DATE:\(day(startDay))",
            "DTEND;VALUE=DATE:\(day(endDay))",
            "SUMMARY:\(escape(title))"
        ]
        if let location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
        if let notes, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
        lines.append(contentsOf: ["END:VEVENT", "END:VCALENDAR"])

        // iCalendar requires CRLF line endings.
        let ics = lines.joined(separator: "\r\n") + "\r\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FreeBNB-Stay.ics")
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

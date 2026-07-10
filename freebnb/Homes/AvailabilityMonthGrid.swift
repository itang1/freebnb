//
//  AvailabilityMonthGrid.swift
//  freebnb
//
//  One month of day cells (feature 16). The host taps them to block and unblock;
//  the guest reads the same grid to see which windows are open. Both surfaces get
//  the same view, because a guest who sees a different calendar from the one the
//  host filled in has been told a small lie.
//

import SwiftUI

struct AvailabilityMonthGrid: View {
    let month: Date
    let blockedDays: Set<Date>
    /// Nil makes the grid read-only, which is the guest-side calendar.
    var onToggle: ((Date) -> Void)?

    private let calendar = Calendar.current
    private var isInteractive: Bool { onToggle != nil }

    private static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.monthTitle.string(from: month))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                ForEach(Array(AvailabilityCalendar.weekdayInitials(calendar: calendar).enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(AvailabilityCalendar.monthGrid(for: month, calendar: calendar).enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day)
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let past = AvailabilityCalendar.isPast(day, calendar: calendar)
        let blocked = blockedDays.contains(calendar.startOfDay(for: day))

        Button {
            onToggle?(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption)
                .fontWeight(blocked ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background(blocked: blocked, past: past))
                .foregroundColor(foreground(blocked: blocked, past: past))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(past || !isInteractive)
        .accessibilityLabel(accessibilityLabel(day, blocked: blocked, past: past))
        .accessibilityHint(past || !isInteractive ? "" : (blocked ? "Tap to unblock" : "Tap to block"))
    }

    private func background(blocked: Bool, past: Bool) -> Color {
        if past { return Color.secondary.opacity(0.06) }
        return blocked ? Color.orange.opacity(0.22) : Color.accent.opacity(0.12)
    }

    private func foreground(blocked: Bool, past: Bool) -> Color {
        if past { return .secondary.opacity(0.4) }
        return blocked ? .orange : .primary
    }

    /// Spelled out rather than left to the number alone: a bare "14" tells a
    /// VoiceOver user nothing about whether the day is open.
    private func accessibilityLabel(_ day: Date, blocked: Bool, past: Bool) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        if past { return "\(date), in the past" }
        return blocked ? "\(date), unavailable" : "\(date), available"
    }
}

/// Shared key for both calendars, so "orange means blocked" is stated once.
struct AvailabilityLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            swatch(Color.accent.opacity(0.12), "Available")
            swatch(Color.orange.opacity(0.22), "Unavailable")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 14, height: 14)
            Text(label)
        }
    }
}

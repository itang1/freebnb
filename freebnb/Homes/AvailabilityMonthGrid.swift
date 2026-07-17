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

/// What a marked day on the grid means. The same grid draws both halves of
/// availability, because they are opposites and a host editing one right after
/// the other should not have to relearn the widget in between.
enum DayMarking {
    /// The host ruled this day out. Guests cannot request across it.
    case blocked
    /// The host affirmatively offered this day (`AvailabilityStance.windows`).
    /// Not a gate — an unmarked day is one the host didn't offer, not one they
    /// refused, and a friend may still ask about it.
    case open

    var tint: Color { self == .blocked ? .orange : .green }

    /// How a marked day reads to VoiceOver, and in the legend.
    var markedTerm: String { self == .blocked ? "unavailable" : "open" }

    /// The opposite. Deliberately vaguer for `.open`: an unmarked day under
    /// `.windows` means "not offered", which is not the same as "unavailable",
    /// and saying the stronger word would put a refusal in the host's mouth.
    var unmarkedTerm: String { self == .blocked ? "available" : "not offered" }

    /// Legend labels. Written out rather than capitalizing the VoiceOver terms,
    /// which reads as a hack and mis-cases anything but plain lowercase ASCII.
    var markedLegend: String { self == .blocked ? "Unavailable" : "Offered" }
    var unmarkedLegend: String { self == .blocked ? "Available" : "Not offered" }
}

struct AvailabilityMonthGrid: View {
    let month: Date
    let markedDays: Set<Date>
    var marking: DayMarking = .blocked
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
        let marked = markedDays.contains(calendar.startOfDay(for: day))

        Button {
            onToggle?(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption)
                .fontWeight(marked ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background(marked: marked, past: past))
                .foregroundColor(foreground(marked: marked, past: past))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(past || !isInteractive)
        .accessibilityLabel(accessibilityLabel(day, marked: marked, past: past))
        .accessibilityHint(hint(marked: marked, past: past))
    }

    private func background(marked: Bool, past: Bool) -> Color {
        if past { return Color.secondary.opacity(0.06) }
        return marked ? marking.tint.opacity(0.22) : Color.accent.opacity(0.12)
    }

    private func foreground(marked: Bool, past: Bool) -> Color {
        if past { return .secondary.opacity(0.4) }
        return marked ? marking.tint : .primary
    }

    /// Spelled out rather than left to the number alone: a bare "14" tells a
    /// VoiceOver user nothing about whether the day is open.
    private func accessibilityLabel(_ day: Date, marked: Bool, past: Bool) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        if past { return "\(date), in the past" }
        return "\(date), \(marked ? marking.markedTerm : marking.unmarkedTerm)"
    }

    private func hint(marked: Bool, past: Bool) -> String {
        guard !past, isInteractive else { return "" }
        switch (marking, marked) {
        case (.blocked, true):  return "Tap to unblock"
        case (.blocked, false): return "Tap to block"
        case (.open, true):     return "Tap to stop offering"
        case (.open, false):    return "Tap to offer"
        }
    }
}

/// Shared key for both calendars, so "orange means blocked" is stated once.
struct AvailabilityLegend: View {
    var marking: DayMarking = .blocked

    var body: some View {
        HStack(spacing: 16) {
            swatch(Color.accent.opacity(0.12), marking.unmarkedLegend)
            swatch(marking.tint.opacity(0.22), marking.markedLegend)
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

#Preview("Blocked") {
    VStack(spacing: 16) {
        AvailabilityLegend()
        AvailabilityMonthGrid(month: .now, markedDays: []) { _ in }
    }
    .padding()
}

#Preview("Open windows") {
    VStack(spacing: 16) {
        AvailabilityLegend(marking: .open)
        AvailabilityMonthGrid(month: .now, markedDays: [], marking: .open) { _ in }
    }
    .padding()
}

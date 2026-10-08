//
//  AvailabilityMonthGrid.swift
//  freebnb
//
//  One month of day cells the host taps to block and unblock in the availability editor.
//  Guests never see it; they learn a date is taken only as a greyed day in StayDateGrid.
//

import SwiftUI

/// What a marked day means. Told apart only in the host's editor; a guest sees every
/// unavailable day as one "unavailable" (see `Home.unavailableRanges`).
enum DayMarking {
    /// The host ruled this day out. Grey: simply closed.
    case blocked
    /// An accepted stay claimed this day. Orange: on the host's calendar, someone will be here.
    case booked

    var tint: Color {
        switch self {
        case .blocked: return .secondary
        case .booked: return .orange
        }
    }

    /// Blocked days sit at lower opacity than booked; grey at orange's weight reads as a disabled control.
    var fillOpacity: Double {
        switch self {
        case .blocked: return 0.14
        case .booked: return 0.22
        }
    }

    /// How a marked day reads to VoiceOver.
    var markedTerm: String {
        switch self {
        case .blocked: return "unavailable"
        case .booked: return "booked"
        }
    }
    var unmarkedTerm: String { "available" }

    /// Legend labels written out; capitalizing the VoiceOver terms mis-cases anything but plain lowercase ASCII.
    var markedLegend: String {
        switch self {
        case .blocked: return "Unavailable"
        case .booked: return "Booked"
        }
    }
    var unmarkedLegend: String { "Available" }
}

struct AvailabilityMonthGrid: View {
    let month: Date
    let markedDays: Set<Date>
    /// Days the host can't toggle (an accepted stay took them): booked tint, never tappable.
    var lockedDays: Set<Date> = []
    /// The meaning of a day in `markedDays`. Locked days always read `.booked`.
    var marking: DayMarking = .blocked
    /// Nil makes the grid read-only.
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
                        .foregroundColor(.secondaryText)
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
        let startOfDay = calendar.startOfDay(for: day)
        let past = AvailabilityCalendar.isPast(day, calendar: calendar)
        let locked = lockedDays.contains(startOfDay)
        let marked = locked || markedDays.contains(startOfDay)
        // A locked day is a booking whatever the grid's default marking says.
        let dayMarking: DayMarking = locked ? .booked : marking

        Button {
            onToggle?(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption)
                .fontWeight(marked ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background(marked: marked, past: past, marking: dayMarking))
                .foregroundColor(foreground(marked: marked, past: past, marking: dayMarking))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(past || !isInteractive || locked)
        .accessibilityLabel(accessibilityLabel(day, marked: marked, past: past, marking: dayMarking))
        .accessibilityHint(hint(marked: marked, past: past, locked: locked))
    }

    private func background(marked: Bool, past: Bool, marking: DayMarking) -> Color {
        if past { return Color.secondaryText.opacity(0.06) }
        return marked ? marking.tint.opacity(marking.fillOpacity) : Color.accent.opacity(0.12)
    }

    private func foreground(marked: Bool, past: Bool, marking: DayMarking) -> Color {
        if past { return .secondaryText.opacity(0.4) }
        return marked ? marking.tint : .primary
    }

    /// Spelled out, since a bare "14" tells VoiceOver nothing about whether the day is open.
    private func accessibilityLabel(_ day: Date, marked: Bool, past: Bool, marking: DayMarking) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        if past { return "\(date), in the past" }
        return "\(date), \(marked ? marking.markedTerm : marking.unmarkedTerm)"
    }

    private func hint(marked: Bool, past: Bool, locked: Bool) -> String {
        guard !past, isInteractive else { return "" }
        // A locked day carries a booking; say it's held rather than offering a dead tap.
        if locked { return "Held by a booking" }
        return marked ? "Tap to unblock" : "Tap to block"
    }
}

/// Key for the host's availability editor, stating what each tint means.
struct AvailabilityLegend: View {
    var marking: DayMarking = .blocked
    var showsBooked: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            swatch(Color.accent.opacity(0.12), marking.unmarkedLegend)
            swatch(marking.tint.opacity(marking.fillOpacity), marking.markedLegend)
            if showsBooked {
                swatch(DayMarking.booked.tint.opacity(DayMarking.booked.fillOpacity), DayMarking.booked.markedLegend)
            }
        }
        .font(.caption)
        .foregroundColor(.secondaryText)
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

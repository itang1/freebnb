//
//  StayDateGrid.swift
//  freebnb
//
//  The guest's date picker: a month of tappable day cells with unavailable days greyed
//  out and tap-refusing. A DatePicker can only bound a contiguous range, which can't
//  express a blocked calendar. The host's editor keeps AvailabilityMonthGrid (single days);
//  this selects a span and never writes anything.
//

import SwiftUI

struct StayDateGrid: View {
    /// Days no stay may pass a night in: blocked plus accepted-stay ranges, merged and indistinguishable (see
    /// `Home.unavailableRanges`).
    let unavailableDays: Set<Date>
    @Binding var checkIn: Date?
    @Binding var checkOut: Date?

    /// How far ahead a guest may look; a year keeps the chevrons finite. Not private,
    /// since the request sheet clamps withheld policy days to the same horizon.
    static let monthsAhead = 12

    @State private var visibleMonth: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    /// Set when a second tap became a new check-in because the span would cross an unavailable day; without
    /// it the selection moves silently and reads as a bug.
    @State private var restartedOnUnavailableDays = false

    private let calendar = Calendar.current

    private static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private var months: [Date] { AvailabilityCalendar.months(count: Self.monthsAhead, calendar: calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            monthHeader
            weekdayHeader

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(AvailabilityCalendar.monthGrid(for: visibleMonth, calendar: calendar).enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day)
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }

            legend

            if restartedOnUnavailableDays {
                Label(
                    "Those dates run through days the host isn't available, so your check in moved to the day you tapped. Pick a check out that doesn't cross a greyed-out day.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundColor(.secondaryText)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // Only this line arriving is worth animating, so the guest notices it.
        .animation(.default, value: restartedOnUnavailableDays)
        // Clearing the dates externally clears the explanation, which describes a selection that's gone.
        .onChange(of: checkIn) { _, new in
            if new == nil { restartedOnUnavailableDays = false }
        }
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!canStep(-1))
            .accessibilityLabel("Previous month")

            Spacer()
            Text(Self.monthTitle.string(from: visibleMonth))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canStep(1))
            .accessibilityLabel("Next month")
        }
        .foregroundColor(.accent)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(AvailabilityCalendar.weekdayInitials(calendar: calendar).enumerated()), id: \.offset) { _, initial in
                Text(initial)
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            swatch(Color.accent, "Your stay")
            swatch(Color.secondaryText.opacity(0.12), "Unavailable")
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

    private func canStep(_ delta: Int) -> Bool {
        guard let target = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return false }
        return months.contains { calendar.isDate($0, equalTo: target, toGranularity: .month) }
    }

    private func step(_ delta: Int) {
        guard canStep(delta), let target = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = target
    }

    // MARK: - Cells

    /// What one day looks like; the most restrictive wins, so past or ruled-out days grey the same inside a
    /// half-made selection.
    private enum CellState {
        case unavailable
        case endpoint
        case inStay
        case available
    }

    private func state(of day: Date) -> CellState {
        if AvailabilityCalendar.isPast(day, calendar: calendar) || unavailableDays.contains(day) {
            return .unavailable
        }
        if let checkIn, calendar.isDate(day, inSameDayAs: checkIn) { return .endpoint }
        if let checkOut, calendar.isDate(day, inSameDayAs: checkOut) { return .endpoint }
        if let checkIn, let checkOut, day > checkIn, day < checkOut { return .inStay }
        return .available
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let startOfDay = calendar.startOfDay(for: day)
        let state = state(of: startOfDay)

        Button {
            select(startOfDay)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption)
                .fontWeight(state == .endpoint ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(background(state))
                .foregroundColor(foreground(state))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(state == .unavailable)
        .accessibilityLabel(accessibilityLabel(startOfDay, state: state))
        .accessibilityHint(state == .unavailable ? "" : "Tap to select")
    }

    private func background(_ state: CellState) -> Color {
        switch state {
        case .unavailable: return Color.secondaryText.opacity(0.12)
        case .endpoint: return .accent
        case .inStay: return Color.accent.opacity(0.25)
        case .available: return Color.accent.opacity(0.10)
        }
    }

    private func foreground(_ state: CellState) -> Color {
        switch state {
        case .unavailable: return .secondaryText.opacity(0.4)
        case .endpoint: return .onAccent
        case .inStay, .available: return .primary
        }
    }

    private func accessibilityLabel(_ day: Date, state: CellState) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        switch state {
        case .unavailable:
            return AvailabilityCalendar.isPast(day, calendar: calendar)
                ? "\(date), in the past"
                : "\(date), unavailable"
        case .endpoint:
            if let checkIn, calendar.isDate(day, inSameDayAs: checkIn), checkOut == nil {
                return "\(date), selected as check in"
            }
            if let checkIn, calendar.isDate(day, inSameDayAs: checkIn) { return "\(date), check in" }
            return "\(date), check out"
        case .inStay:
            return "\(date), part of your stay"
        case .available:
            return "\(date), available"
        }
    }

    // MARK: - Selection

    /// First tap sets check-in. A later tap closes the stay only if every night between is
    /// free; otherwise it starts a new selection. Tapping check-in again, or an earlier day, restarts.
    private func select(_ day: Date) {
        guard let start = checkIn, checkOut == nil, day > start else {
            restartedOnUnavailableDays = false
            checkIn = day
            checkOut = nil
            return
        }
        guard AvailabilityCalendar.isStaySelectable(
            checkIn: start,
            checkOut: day,
            unavailableDays: unavailableDays,
            calendar: calendar
        ) else {
            restartedOnUnavailableDays = true
            checkIn = day
            checkOut = nil
            return
        }
        restartedOnUnavailableDays = false
        checkOut = day
    }
}

#Preview {
    @Previewable @State var checkIn: Date? = nil
    @Previewable @State var checkOut: Date? = nil
    return StayDateGrid(
        unavailableDays: AvailabilityCalendar.blockedDays(
            in: [DateRange(start: Date(), end: Date().addingTimeInterval(4 * 86_400))]
        ),
        checkIn: $checkIn,
        checkOut: $checkOut
    )
    .padding()
}

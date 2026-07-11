//
//  AvailabilityEditorView.swift
//  freebnb
//
//  Host view for marking dates as blocked/unavailable (feature 16). The host taps
//  days on a month grid; the flat set of blocked days is collapsed back into
//  `DateRange`s only on save, because ranges are the storage format and a set is
//  what a tappable calendar wants. See `AvailabilityCalendar`.
//

import SwiftUI

struct AvailabilityEditorView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(\.dismiss) private var dismiss

    @State private var blockedDays: Set<Date>
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Rebuilt only when the blocked days change. Writing the .ics inside `body`
    /// would put a file write on every SwiftUI render pass.
    @State private var exportURL: URL?

    /// A year is as far ahead as anyone plans a spare couch, and it bounds the
    /// number of grids the scroll view has to build.
    private static let monthsAhead = 12

    init(listing: Home) {
        let upcoming = AvailabilityCalendar.upcoming(listing.blockedDateRanges ?? [])
        _blockedDays = State(initialValue: AvailabilityCalendar.blockedDays(in: upcoming))
    }

    /// Derived on demand rather than mirrored into state, so the summary list can
    /// never disagree with the grid above it.
    private var blockedRanges: [DateRange] {
        AvailabilityCalendar.ranges(from: blockedDays)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Tap the days when your listing is unavailable. Guests cannot request stays that overlap a blocked day.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    AvailabilityLegend()

                    ForEach(AvailabilityCalendar.months(count: Self.monthsAhead), id: \.self) { month in
                        AvailabilityMonthGrid(month: month, blockedDays: blockedDays) { day in
                            blockedDays = AvailabilityCalendar.toggling(day, in: blockedDays)
                        }
                    }

                    summary

                    if let errorMessage {
                        InlineErrorLabel(message: errorMessage)
                    }
                }
                .padding()
            }
            .background(Color.primaryBackground.ignoresSafeArea())
            .navigationTitle("Availability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .disabled(isSaving)
            .task(id: blockedDays) { refreshExport() }
        }
    }

    // MARK: - Summary and export

    @ViewBuilder
    private var summary: some View {
        let ranges = blockedRanges
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked periods")
                .font(.headline)

            if ranges.isEmpty {
                Label("No blocked dates — all dates available.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(ranges) { range in
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.minus")
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rangeLabel(range))
                                .font(.subheadline)
                            Text(durationLabel(range))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // Handed to the share sheet rather than written through EventKit,
                // which would ask for calendar permission just to give the host
                // back what they typed.
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export to Calendar", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// Rebuilds the .ics for the current blocked periods. Nil when nothing is
    /// blocked, which is also what hides the button.
    private func refreshExport() {
        exportURL = CalendarInvite.icsFile(
            events: blockedRanges.enumerated().map { index, range in
                CalendarInvite.Event(
                    uid: "\(listing.id)-blocked-\(index)",
                    title: "Unavailable — \(listing.address.city)",
                    location: "\(listing.address.city), \(listing.address.state)",
                    notes: nil,
                    startDay: range.start,
                    endDay: range.end
                )
            },
            filename: "FreeBNB-Availability.ics"
        )
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        var updated = listing
        let ranges = blockedRanges
        updated.blockedDateRanges = ranges.isEmpty ? nil : ranges
        do {
            try await homeStore.save(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Labels

    /// `end` is exclusive, so the last blocked night is the day before it. Showing
    /// the exclusive bound would tell the host they had blocked a day they hadn't.
    private func rangeLabel(_ range: DateRange) -> String {
        let formatter = AppDateFormatters.shortDay
        let lastBlocked = Calendar.current.date(byAdding: .day, value: -1, to: range.end) ?? range.start
        if Calendar.current.isDate(range.start, inSameDayAs: lastBlocked) {
            return formatter.string(from: range.start)
        }
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: lastBlocked))"
    }

    private func durationLabel(_ range: DateRange) -> String {
        let days = Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        return "\(days) day\(days == 1 ? "" : "s") blocked"
    }
}

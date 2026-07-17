//
//  AvailabilityEditorView.swift
//  freebnb
//
//  Host view for the two halves of availability (features 16 and 42): the
//  standing posture ("always open to friends", "open on these dates") and the
//  blocked days that are the exceptions to it.
//
//  Both grids work the same way. The host taps days; the flat set is collapsed
//  back into `DateRange`s only on save, because ranges are the storage format and
//  a set is what a tappable calendar wants. See `AvailabilityCalendar`.
//
//  The stance picker comes first on purpose. Blocked dates alone are a negative,
//  and a host who has blocked nothing has said nothing — which the feed used to
//  read as a year of free dates. The stance is where the host actually answers.
//

import SwiftUI

struct AvailabilityEditorView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(\.dismiss) private var dismiss

    @State private var stance: AvailabilityStance
    @State private var blockedDays: Set<Date>
    @State private var openDays: Set<Date>
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Rebuilt only when the blocked days change. Writing the .ics inside `body`
    /// would put a file write on every SwiftUI render pass.
    @State private var exportURL: URL?

    /// A year is as far ahead as anyone plans a spare couch, and it bounds the
    /// number of grids the scroll view has to build.
    private static let monthsAhead = 12

    init(listing: Home) {
        self.listing = listing
        let upcoming = AvailabilityCalendar.upcoming(listing.blockedDateRanges ?? [])
        _blockedDays = State(initialValue: AvailabilityCalendar.blockedDays(in: upcoming))
        _stance = State(initialValue: listing.stance)
        // Read straight from the stored ranges rather than `openWindows()`, which
        // returns [] for any stance but `.windows`. A host switching to `.windows`
        // and back should find their dates where they left them, not wiped.
        let openUpcoming = AvailabilityCalendar.upcoming(listing.openDateRanges ?? [])
        _openDays = State(initialValue: AvailabilityCalendar.blockedDays(in: openUpcoming))
    }

    /// Derived on demand rather than mirrored into state, so the summary list can
    /// never disagree with the grid above it.
    private var blockedRanges: [DateRange] {
        AvailabilityCalendar.ranges(from: blockedDays)
    }

    private var openRanges: [DateRange] {
        AvailabilityCalendar.ranges(from: openDays)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stancePicker

                    if stance == .windows {
                        openWindowsSection
                    }

                    blockedSection

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
                        .disabled(isSaving || !canSave)
                }
            }
            .disabled(isSaving)
            .task(id: blockedDays) { refreshExport() }
        }
    }

    /// `.windows` with no dates chosen is the one unsaveable combination: it says
    /// "I'm open on specific dates" and then names none, which reads to a guest as
    /// a listing with no availability at all rather than as the host's intent.
    private var canSave: Bool {
        stance != .windows || !openDays.isEmpty
    }

    // MARK: - Stance

    @ViewBuilder
    private var stancePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Are you open to guests?")
                .font(.headline)

            Text("Friends see this on your listing. It's the difference between \"I'd love to host\" and \"nobody has asked me yet\".")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(AvailabilityStance.allCases, id: \.self) { option in
                stanceRow(option)
            }
        }
    }

    private func stanceRow(_ option: AvailabilityStance) -> some View {
        Button {
            stance = option
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stance == option ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(stance == option ? .accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text(option.editorDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stance == option ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Open windows

    @ViewBuilder
    private var openWindowsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dates you're offering")
                .font(.headline)

            Text("Tap the days you'd like friends to come. Friends can still ask about other dates.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            AvailabilityLegend(marking: .open)

            ForEach(AvailabilityCalendar.months(count: Self.monthsAhead), id: \.self) { month in
                AvailabilityMonthGrid(month: month, markedDays: openDays, marking: .open) { day in
                    openDays = AvailabilityCalendar.toggling(day, in: openDays)
                }
            }

            if openDays.isEmpty {
                Label("Pick at least one day, or choose \"Ask me anytime\" above.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                ForEach(openRanges) { range in
                    rangeRow(range, marking: .open)
                }
            }
        }
    }

    // MARK: - Blocked days

    @ViewBuilder
    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dates you can't host")
                .font(.headline)

            Text("Tap the days your listing is unavailable. Friends cannot request stays that overlap a blocked day.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            AvailabilityLegend()

            ForEach(AvailabilityCalendar.months(count: Self.monthsAhead), id: \.self) { month in
                AvailabilityMonthGrid(month: month, markedDays: blockedDays) { day in
                    blockedDays = AvailabilityCalendar.toggling(day, in: blockedDays)
                }
            }

            summary
        }
    }

    // MARK: - Summary and export

    @ViewBuilder
    private var summary: some View {
        let ranges = blockedRanges
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked periods")
                .font(.subheadline.weight(.semibold))

            if ranges.isEmpty {
                // Deliberately not "all dates available": an empty block list only
                // means the host ruled nothing out, and the stance above is the
                // one place that answers whether they're actually offering.
                Label("No blocked dates.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(ranges) { range in
                    rangeRow(range, marking: .blocked)
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

    /// One row of the "here's what you just drew" list, shared by both grids so a
    /// blocked stretch and an offered one read identically apart from the colour.
    private func rangeRow(_ range: DateRange, marking: DayMarking) -> some View {
        HStack(spacing: 10) {
            Image(systemName: marking == .blocked ? "calendar.badge.minus" : "calendar.badge.plus")
                .foregroundColor(marking.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rangeLabel(range))
                    .font(.subheadline)
                Text(durationLabel(range, marking: marking))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
        updated.availabilityStance = stance
        // Only `.windows` has windows. Clearing them for every other stance keeps
        // the document honest about what the host is actually offering, rather
        // than leaving dates behind that nothing reads but the rules still allow.
        let offered = openRanges
        updated.openDateRanges = (stance == .windows && !offered.isEmpty) ? offered : nil
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

    private func durationLabel(_ range: DateRange, marking: DayMarking) -> String {
        let days = Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        return "\(days) day\(days == 1 ? "" : "s") \(marking == .blocked ? "blocked" : "offered")"
    }
}

#Preview {
    AvailabilityEditorView(listing: PreviewData.home)
        .previewEnvironment()
}

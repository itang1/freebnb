//
//  AvailabilityEditorView.swift
//  freebnb
//
//  Host view for availability: the days the host can't host. The flat tapped set
//  collapses into `DateRange`s only on save (see `AvailabilityCalendar`).
//
//  Blocking is reason-free on purpose: "unavailable" never says why, which keeps
//  a host's plans their own on a listing all their friends can see.
//

import SwiftUI

struct AvailabilityEditorView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var blockedDays: Set<Date> = []
    /// The turnover gap held around every confirmed stay; `loadedBufferHours` is what it arrived as, so an
    /// untouched buffer costs no write.
    @State private var bufferHours = ListingAvailability.defaultBufferHours
    @State private var loadedBufferHours = ListingAvailability.defaultBufferHours
    /// The server's half, loaded with the host's. Held apart because the listing
    /// only carries the merged copy, which this screen must not show.
    @State private var bookedRanges: [DateRange] = []
    /// The calendar is a separate document, so nothing is editable until it
    /// arrives, or a host could "unblock" days by saving before their blocks loaded.
    @State private var isLoading = true
    @State private var applyToAllHomes = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Rebuilt only when blocked days change; writing the .ics in `body` would hit disk every render.
    @State private var exportURL: URL?

    /// A year ahead is as far as anyone plans a spare couch, and it bounds the grids built.
    private static let monthsAhead = 12

    init(listing: Home) {
        self.listing = listing
    }

    /// Pulls the unmerged calendar; the host's half seeds the grid, the server's is drawn locked.
    private func load() async {
        let availability = await homeStore.availability(for: listing.id)
        blockedDays = AvailabilityCalendar.blockedDays(
            in: AvailabilityCalendar.upcoming(availability.blockedDateRanges)
        )
        bookedRanges = availability.bookedDateRanges
        bufferHours = availability.bufferHours
        loadedBufferHours = availability.bufferHours
        isLoading = false
    }

    /// Buffer choices in whole days, since the calendar is day-granular and "2
    /// hours" would draw a full day. Stored as hours, the setting's unit.
    private static let bufferOptions: [Int] = [0, 24, 48, 72]

    private static func bufferLabel(_ hours: Int) -> String {
        switch hours {
        case 0:  return "No buffer"
        default:
            let days = AvailabilityCalendar.bufferDays(forHours: hours)
            return "\(days) day\(days == 1 ? "" : "s")"
        }
    }

    /// Derived on demand so the summary can't disagree with the grid.
    private var blockedRanges: [DateRange] {
        AvailabilityCalendar.ranges(from: blockedDays)
    }

    /// Days an accepted stay has taken, read from the listing and shown locked;
    /// not part of `blockedDays`, which the host edits and saves.
    private var bookedDays: Set<Date> {
        AvailabilityCalendar.blockedDays(in: AvailabilityCalendar.upcoming(bookedRanges))
    }

    /// The host's other homes that "apply to all" would reach. Empty (option hidden)
    /// unless the user hosts this listing and at least one more.
    private var otherHostedListings: [Home] {
        guard listing.isHostedBy(authManager.userID) else { return [] }
        return homeStore.managedListings.filter {
            $0.isHostedBy(authManager.userID) && $0.id != listing.id
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    blockedSection

                    bufferSection

                    applyToAllSection

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
                        .disabled(isSaving || isLoading)
                }
            }
            .disabled(isSaving || isLoading)
            .task { await load() }
            .task(id: blockedDays) { refreshExport() }
        }
    }

    // MARK: - Blocked days

    @ViewBuilder
    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dates you can't host")
                .font(.headline)

            Text("Tap the days your listing is unavailable. Friends cannot request stays that overlap a blocked day, and accepted stays block themselves.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)

            let booked = bookedDays

            // The host's own calendar is where the two are told apart, so the booked key appears only with a
            // booking.
            AvailabilityLegend(showsBooked: !booked.isEmpty)

            ForEach(AvailabilityCalendar.months(count: Self.monthsAhead), id: \.self) { month in
                AvailabilityMonthGrid(month: month, markedDays: blockedDays, lockedDays: booked) { day in
                    blockedDays = AvailabilityCalendar.toggling(day, in: blockedDays)
                }
            }

            if !booked.isEmpty {
                Label("Dates a guest has booked are filled in for you and can't be changed here. Cancel the stay to free them.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            summary
        }
    }

    // MARK: - Turnover buffer

    /// The gap held automatically around every confirmed stay. Like everything
    /// here it is reason-free to the guest: held days read as unavailable.
    @ViewBuilder
    private var bufferSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turnover buffer")
                .font(.headline)

            Text("Holds time around every confirmed stay so you have room to reset between guests. Friends see the held days as unavailable, the same as any other closed date.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)

            Picker("Turnover buffer", selection: $bufferHours) {
                ForEach(Self.bufferOptions, id: \.self) { hours in
                    Text(Self.bufferLabel(hours)).tag(hours)
                }
            }
            .pickerStyle(.segmented)

            Text(bufferHours == 0
                 ? "A guest can check in the day another checks out."
                 : "The day before a check-in and the day after a checkout close automatically.")
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
    }

    // MARK: - Apply to all homes

    /// Offered only to a host with more than one home. Copies the dates onto the
    /// other homes once, adding to what each has, and doesn't keep them in step.
    @ViewBuilder
    private var applyToAllSection: some View {
        let others = otherHostedListings
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $applyToAllHomes) {
                    Text("Also block these dates on your other homes")
                        .font(.subheadline.weight(.medium))
                }
                Text("Adds them to your other \(others.count) listing\(others.count == 1 ? "" : "s"). Each home keeps its own blocked dates, and they don't stay linked afterward.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
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
                // Not "all dates available": an empty list only means nothing is ruled out; a friend still asks.
                Label("No blocked dates.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(ranges) { range in
                    rangeRow(range)
                }
                // Handed to the share sheet rather than EventKit, which would ask for calendar permission.
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

    /// One row of the list of blocked stretches.
    private func rangeRow(_ range: DateRange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.minus")
                .foregroundColor(DayMarking.blocked.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rangeLabel(range))
                    .font(.subheadline)
                Text(durationLabel(range))
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Rebuilds the .ics for the blocked periods; nil when nothing is blocked (which hides the button).
    private func refreshExport() {
        exportURL = CalendarInvite.icsFile(
            events: blockedRanges.enumerated().map { index, range in
                CalendarInvite.Event(
                    uid: "\(listing.id)-blocked-\(index)",
                    title: "Unavailable: \(listing.address.city)",
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
        let ranges = blockedRanges
        // Buffer first when changed, so the blocked-range save republishes with the new padding. Skipped if
        // untouched.
        if bufferHours != loadedBufferHours {
            do {
                try await homeStore.saveBufferHours(bufferHours, for: listing)
                loadedBufferHours = bufferHours
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        do {
            try await homeStore.saveBlockedRanges(ranges, for: listing)
        } catch {
            // This listing didn't save, so don't fan out onto the others.
            errorMessage = error.localizedDescription
            return
        }
        // The fan-out unions these dates onto other homes. A failure is reported by
        // name and leaves this (saved) listing alone, so the host can retry.
        if applyToAllHomes {
            let failed = await homeStore.applyBlockedRangesToOtherHostedListings(
                ranges, excludingID: listing.id, hostUserID: authManager.userID
            )
            if !failed.isEmpty {
                errorMessage = "Saved here, but \(failed.count) of your other homes couldn't be updated. Try again to finish."
                return
            }
        }
        dismiss()
    }

    // MARK: - Labels

    /// `end` is exclusive, so the last blocked night is the day before it.
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

#Preview {
    AvailabilityEditorView(listing: PreviewData.home)
        .previewEnvironment()
}

//
//  AvailabilityEditorView.swift
//  freebnb
//
//  Host view for availability (feature 16): the days the host can't host. The
//  host taps days; the flat set is collapsed back into `DateRange`s only on save,
//  because ranges are the storage format and a set is what a tappable calendar
//  wants. See `AvailabilityCalendar`.
//
//  Blocking is reason-free on purpose. "Unavailable" never says why — a trip, a
//  renovation, another guest, or simply not this week — and that ambiguity is
//  what keeps a host's plans their own on a listing their friends can all see.
//

import SwiftUI

struct AvailabilityEditorView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var blockedDays: Set<Date> = []
    /// The turnover gap the host wants held around every confirmed stay. Loaded
    /// with the calendar and written back on save; `loadedBufferHours` is what it
    /// arrived as, so an untouched buffer costs no write.
    @State private var bufferHours = ListingAvailability.defaultBufferHours
    @State private var loadedBufferHours = ListingAvailability.defaultBufferHours
    /// The server's half, loaded alongside the host's. Held rather than derived
    /// from `listing` because the listing only carries the merged copy now, and
    /// merged is exactly the thing this screen must not show.
    @State private var bookedRanges: [DateRange] = []
    /// The calendar lives in a separate document, so unlike every other field on
    /// this screen it isn't in hand when the sheet opens. Nothing is editable
    /// until it arrives: a grid that drew empty and accepted taps would let a host
    /// "unblock" days by saving before their own blocks had loaded.
    @State private var isLoading = true
    @State private var applyToAllHomes = false
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
    }

    /// Pulls the unmerged calendar. The host's half seeds the grid; the server's
    /// half is kept aside so those days can be drawn locked.
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

    /// The buffer choices, in whole turnover days because the calendar is
    /// day-granular: a sub-day buffer would still close a whole date, so offering
    /// "2 hours" would draw a day and read as a lie. Stored as hours all the same,
    /// which is the unit the setting is defined in.
    private static let bufferOptions: [Int] = [0, 24, 48, 72]

    private static func bufferLabel(_ hours: Int) -> String {
        switch hours {
        case 0:  return "No buffer"
        default:
            let days = AvailabilityCalendar.bufferDays(forHours: hours)
            return "\(days) day\(days == 1 ? "" : "s")"
        }
    }

    /// Derived on demand rather than mirrored into state, so the summary list can
    /// never disagree with the grid above it.
    private var blockedRanges: [DateRange] {
        AvailabilityCalendar.ranges(from: blockedDays)
    }

    /// The days an accepted stay has taken. Read from the listing (the server
    /// keeps it current) rather than toggled, so the grid can show them filled in
    /// and locked. Not folded into `blockedDays`: those are the host's to edit and
    /// get written back on save, and a booking is neither.
    private var bookedDays: Set<Date> {
        AvailabilityCalendar.blockedDays(in: AvailabilityCalendar.upcoming(bookedRanges))
    }

    /// The host's other homes, the ones "apply to all" would reach. Only listings
    /// this user hosts — a co-host editing someone else's availability has no "my
    /// other homes" to speak of. Empty (so the option stays hidden) unless the user
    /// hosts this listing and at least one more.
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

            // The host's own calendar is the one place the two are told apart, so
            // the booked key only appears once there is a booking to explain.
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

    /// The gap held automatically around every confirmed stay, so a checkout and
    /// the next check-in never land on the same day without the host blocking it by
    /// hand each time. Reason-free to the guest like everything else here: the held
    /// days simply read as unavailable, indistinguishable from a booking or a
    /// closed week.
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

    /// Offered only to a host with more than one home, and phrased as a plain
    /// choice: it copies the dates onto the other homes once, adding to whatever
    /// each already has rather than replacing it, and does not keep them in step
    /// afterwards. Hidden entirely for a single-home host and for a co-host, for
    /// whom "all my homes" is either one home or none.
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
                // Deliberately not "all dates available": an empty block list only
                // means the host has ruled nothing out, which is not the same as a
                // promise that every date is free. A friend still asks.
                Label("No blocked dates.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(ranges) { range in
                    rangeRow(range)
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

    /// One row of the "here's what you just drew" list of blocked stretches.
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

    /// Rebuilds the .ics for the current blocked periods. Nil when nothing is
    /// blocked, which is also what hides the button.
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
        // The buffer first, when it changed, so the blocked-range save that follows
        // republishes the union with the new padding already in the cache. An
        // untouched buffer is skipped: it would only rewrite the same value.
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
            // This listing didn't save, so don't fan out onto the others — the
            // host would be left with the change applied everywhere but here.
            errorMessage = error.localizedDescription
            return
        }
        // The fan-out unions these dates onto the host's other homes. A failure
        // here is reported by name and leaves this listing (already saved) alone,
        // so the host can retry without losing what took.
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

#Preview {
    AvailabilityEditorView(listing: PreviewData.home)
        .previewEnvironment()
}

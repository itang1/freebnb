//
//  AvailabilityEditorView.swift
//  freebnb
//
//  Host view for marking dates as blocked/unavailable.
//

import SwiftUI

struct AvailabilityEditorView: View {
    let listing: Home

    @Environment(HomeStore.self) private var homeStore
    @Environment(\.dismiss) private var dismiss

    @State private var blockedRanges: [DateRange]
    @State private var newStart: Date = Calendar.current.startOfDay(for: Date())
    @State private var newEnd: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    )
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(listing: Home) {
        self.listing = listing
        _blockedRanges = State(initialValue: (listing.blockedDateRanges ?? [])
            .filter { $0.end > Date() }
            .sorted { $0.start < $1.start })
    }

    private var canAdd: Bool {
        newEnd > newStart && !overlapsExisting(start: newStart, end: newEnd)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Mark dates when your listing is unavailable. Guests cannot request stays that overlap a blocked period.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("Block a date range") {
                    DatePicker("Start", selection: $newStart, in: Date()..., displayedComponents: .date)
                    DatePicker("End", selection: $newEnd,
                               in: (Calendar.current.date(byAdding: .day, value: 1, to: newStart) ?? newStart)...,
                               displayedComponents: .date)
                    if overlapsExisting(start: newStart, end: newEnd) {
                        Label("Overlaps an existing blocked range", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("Add blocked range") {
                        addRange()
                    }
                    .disabled(!canAdd)
                    .foregroundColor(canAdd ? .appTeal : .secondary)
                }

                if !blockedRanges.isEmpty {
                    Section("Blocked periods") {
                        ForEach(blockedRanges) { range in
                            HStack {
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
                        .onDelete { indexSet in
                            blockedRanges.remove(atOffsets: indexSet)
                        }
                    }
                } else {
                    Section {
                        Label("No blocked dates — all dates available.", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
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
        }
    }

    private func addRange() {
        let range = DateRange(start: newStart, end: newEnd)
        blockedRanges.append(range)
        blockedRanges.sort { $0.start < $1.start }
        newStart = Calendar.current.startOfDay(for: Date())
        newEnd = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )
    }

    private func overlapsExisting(start: Date, end: Date) -> Bool {
        blockedRanges.contains { $0.overlaps(checkIn: start, checkOut: end) }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        var updated = listing
        updated.blockedDateRanges = blockedRanges.isEmpty ? nil : blockedRanges
        do {
            try await homeStore.save(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rangeLabel(_ range: DateRange) -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: range.start)) – \(f.string(from: range.end))"
    }

    private func durationLabel(_ range: DateRange) -> String {
        let days = Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        return "\(days) day\(days == 1 ? "" : "s") blocked"
    }
}

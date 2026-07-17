//
//  OfferStaySheet.swift
//  freebnb
//
//  Host-side sheet for offering a listing to a friend (feature 43): "my place is
//  free Mar 3–10, want it?"
//
//  The mirror of `RequestStaySheet`, and deliberately shaped like it — same date
//  pickers, same conflict warnings, same note field — because it becomes the same
//  stay document. The differences are the ones that matter: the host picks a
//  person instead of a place, and the fields that belong to the guest (their party
//  size, their arrival time, their note) are left for the guest to fill in if they
//  say yes. The rules reject an offer that tries to write them.
//
//  This exists because every other host action in the app is a reply. Until a
//  guest asked, a recruited host who opened FreeBNB found an empty room and no
//  reason to come back.
//

import SwiftUI

struct OfferStaySheet: View {
    let listing: Home

    @Environment(StayRequestStore.self) private var requestStore
    @Environment(MessageStore.self) private var messageStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var guestUserID: String?
    @State private var checkIn: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    )
    @State private var checkOut: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
    )
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var nights: Int {
        max(Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0, 0)
    }

    /// Friends who can actually see this listing. The rules require the recipient
    /// to be in the listing's read ACL, so offering to anyone else would be
    /// rejected on write — better to never present them.
    private var offerableFriends: [String] {
        let viewers = Set(listing.allowedViewerIDs ?? [])
        return friendStore.friendIDs.filter { viewers.contains($0) }
    }

    private var blockedConflict: DateRange? {
        listing.blockedDateRanges?.first { $0.overlaps(checkIn: checkIn, checkOut: checkOut) }
    }

    /// A stay already accepted for this listing over the same dates. The host can
    /// read every request to their own listing, so unlike the guest side this is a
    /// complete check — but it is still only a courtesy: the callable's
    /// transaction is what actually stops the double booking when the guest says
    /// yes, which may be days from now and after another guest has been accepted.
    private var acceptedConflict: StayRequest? {
        requestStore.incomingRequests.first { req in
            req.listingID == listing.id
                && req.status == .accepted
                && req.overlaps(checkIn: checkIn, checkOut: checkOut)
        }
    }

    /// An offer for these dates that this friend hasn't answered yet. Sending a
    /// second one would read as nagging, which an offer must never do.
    private var duplicateOffer: StayRequest? {
        guard let guestUserID else { return nil }
        return requestStore.incomingRequests.first { req in
            req.listingID == listing.id
                && req.guestUserID == guestUserID
                && req.status == .offered
                && req.overlaps(checkIn: checkIn, checkOut: checkOut)
        }
    }

    private var canSend: Bool {
        !isSending && guestUserID != nil && checkOut > checkIn
            && nights <= listing.guestPolicy.maxStayDays
            && blockedConflict == nil && acceptedConflict == nil && duplicateOffer == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .foregroundColor(.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.displayTitle)
                                .font(.subheadline.weight(.semibold))
                            Text("\(listing.address.city), \(listing.address.state)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                friendSection
                datesSection

                Section("Note (optional)") {
                    TextField("Anything they should know?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Text("They'll get one notification and can say yes or no. Nothing is booked until they accept.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Offer Your Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Offer") { Task { await send() } }
                        .disabled(!canSend)
                }
            }
            .disabled(isSending)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var friendSection: some View {
        Section("Who's it for?") {
            if offerableFriends.isEmpty {
                Text("None of your friends can see this listing yet. Add friends, and they'll show up here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Picker("Friend", selection: $guestUserID) {
                    Text("Choose a friend").tag(String?.none)
                    ForEach(offerableFriends, id: \.self) { id in
                        Text(userProfileStore.displayName(for: id) ?? "Friend").tag(String?.some(id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var datesSection: some View {
        Section("Dates") {
            DatePicker("Free from", selection: $checkIn, in: Date()..., displayedComponents: .date)
            DatePicker("Free until", selection: $checkOut, in: (Calendar.current.date(byAdding: .day, value: 1, to: checkIn) ?? checkIn)..., displayedComponents: .date)

            if nights > 0 {
                HStack {
                    Text("Duration")
                    Spacer()
                    Text("\(nights) night\(nights == 1 ? "" : "s")")
                        .foregroundColor(nights > listing.guestPolicy.maxStayDays ? .red : .secondary)
                }
            }
            if nights > listing.guestPolicy.maxStayDays {
                Label("Your max stay for this place is \(listing.guestPolicy.maxStayDays) nights", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let conflict = blockedConflict {
                let f = AppDateFormatters.shortDay
                Label("You've blocked \(f.string(from: conflict.start)) – \(f.string(from: conflict.end))", systemImage: "calendar.badge.minus")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let conflict = acceptedConflict {
                let f = AppDateFormatters.shortDay
                Label("You've already accepted a stay here \(f.string(from: conflict.checkIn)) – \(f.string(from: conflict.checkOut))", systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if duplicateOffer != nil {
                Label("You've already offered these dates to them, and they haven't answered yet.", systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Send

    private func send() async {
        guard let guestUserID else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await requestStore.offer(
                listing: listing,
                guestUserID: guestUserID,
                checkIn: checkIn,
                checkOut: checkOut,
                hostNote: note
            )
            // The same courtesy note a request posts, so the offer shows up in the
            // thread the two of them already share rather than only in a tab.
            messageStore.sendStayEvent(
                StayEvent(kind: .offered, dateRange: dateRangeText()),
                senderUserID: authManager.userID,
                recipientUserID: guestUserID
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dateRangeText() -> String {
        let f = AppDateFormatters.shortDay
        return "\(f.string(from: checkIn)) – \(f.string(from: checkOut)) · \(nights) night\(nights == 1 ? "" : "s")"
    }
}

#Preview {
    OfferStaySheet(listing: PreviewData.home)
        .previewEnvironment()
}

//
//  GuestNoteTests.swift
//  freebnbTests
//
//  The pure half of a guest's private notes, plus the repository seam.
//
//  The half that actually enforces the promise is `firestore.rules`
//  (rules-tests/guest_notes.test.mjs): nothing in this file can stop a host
//  reading a note, and nothing here should be read as though it could. What is
//  tested here is the part the client owns — ordering, subject matching,
//  normalization, and the "ask once" arithmetic behind the post-trip prompt.
//
//  `GuestNoteStore` itself binds its guest id from an Auth state listener and so
//  is not directly constructible under test, exactly as `FriendNoteStore` is
//  not; its pure inputs and its repository are covered instead.
//

import Foundation
import Testing
@testable import freebnb

private func note(
    _ id: String,
    type: GuestNoteSubjectType = .host,
    about subject: String = "host-1",
    text: String = "Warm host, easy check-in.",
    stay: String? = nil,
    created: Date? = nil,
    updated: Date? = nil
) -> GuestNote {
    GuestNote(
        id: id,
        subjectType: type,
        subjectID: subject,
        text: text,
        stayRequestID: stay,
        createdAt: created,
        updatedAt: updated
    )
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 86_400 * Double(n)) }

// MARK: - The model

@Suite("Guest note text")
struct GuestNoteTextTests {
    @Test("whitespace-only text is nothing to save")
    func blankIsNil() {
        #expect(GuestNote.normalized("   \n\t ") == nil)
        #expect(GuestNote.normalized("") == nil)
    }

    @Test("text is trimmed rather than stored with its edges")
    func trims() {
        #expect(GuestNote.normalized("  quiet street, thin walls  ") == "quiet street, thin walls")
    }

    /// The cap exists in three places — here, `firestore.rules`, and the
    /// composer's character counter. The client cutting to it is what keeps an
    /// over-long note a field error instead of a permission denial.
    @Test("text is cut to the cap the rules enforce")
    func clampsToCap() {
        let long = String(repeating: "x", count: GuestNote.maxLength + 500)
        #expect(GuestNote.normalized(long)?.count == GuestNote.maxLength)
    }
}

@Suite("Guest note ordering and subject")
struct GuestNoteOrderingTests {
    @Test("notes come back newest first")
    func newestFirst() {
        let sorted = [
            note("a", created: day(1)),
            note("c", created: day(3)),
            note("b", created: day(2))
        ].sortedByDate()
        #expect(sorted.map(\.id) == ["c", "b", "a"])
    }

    /// A note whose server timestamp hasn't landed yet is the one just written,
    /// and it belongs at the top rather than at the bottom where a nil sorts.
    @Test("a note still awaiting its server timestamp floats to the top")
    func pendingWriteFirst() {
        let sorted = [note("a", created: day(2)), note("new", created: nil)].sortedByDate()
        #expect(sorted.map(\.id) == ["new", "a"])
    }

    @Test("notes about one host exclude everyone else's")
    func filtersByHost() {
        let all = [
            note("a", type: .host, about: "host-1", created: day(1)),
            note("b", type: .host, about: "host-2", created: day(2)),
            note("c", type: .host, about: "host-1", created: day(3))
        ]
        #expect(all.about(.host, "host-1").map(\.id) == ["c", "a"])
        #expect(all.about(.host, "host-2").map(\.id) == ["b"])
        #expect(all.about(.host, "nobody").isEmpty)
    }

    /// A host uid and a listing id could collide as bare strings; the subject
    /// type is part of the identity, so a listing note never leaks into a host's
    /// list and vice versa.
    @Test("a host note and a listing note that share an id never mix")
    func typeIsPartOfIdentity() {
        let shared = "shared-id"
        let all = [
            note("h", type: .host, about: shared, created: day(1)),
            note("l", type: .listing, about: shared, created: day(2))
        ]
        #expect(all.about(.host, shared).map(\.id) == ["h"])
        #expect(all.about(.listing, shared).map(\.id) == ["l"])
    }

    /// Both timestamps are server-stamped in one commit on create, so they land
    /// close together but not identical; "edited" has to mean a real later edit.
    @Test("a note is only 'edited' once it has actually been revised")
    func editedFlag() {
        #expect(note("a", created: day(1), updated: day(1)).wasEdited == false)
        #expect(note("b", created: day(1), updated: day(1).addingTimeInterval(0.4)).wasEdited == false)
        #expect(note("c", created: day(1), updated: day(2)).wasEdited)
        #expect(note("d", created: nil, updated: nil).wasEdited == false)
    }
}

// MARK: - The post-trip prompt

@Suite("Guest note post-trip prompt")
struct GuestNotePromptTests {
    private let host = "host-1"
    private let guest = "guest-1"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stay(
        status: StayRequestStatus = .completed,
        guestUserID: String? = nil,
        endedDaysAgo: Double
    ) -> StayRequest {
        let ended = now.addingTimeInterval(-endedDaysAgo * 86_400)
        return StayRequest(
            listingID: "listing-1",
            listingCity: "Town",
            listingHostName: "Host",
            hostUserID: host,
            guestUserID: guestUserID ?? guest,
            checkIn: ended.addingTimeInterval(-2 * 86_400),
            checkOut: ended,
            status: status,
            completedAt: ended
        )
    }

    @Test("a trip that just ended is offered")
    func recentTripIsOffered() {
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 1), guestID: guest, isSettled: false, now: now))
    }

    /// The reason the window exists: shipping this must not greet a traveler with
    /// a prompt for every trip they have ever taken.
    @Test("a trip from long ago is not offered")
    func oldTripIsNotOffered() {
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 400), guestID: guest, isSettled: false, now: now) == false)
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 15), guestID: guest, isSettled: false, now: now) == false)
    }

    @Test("the window's last day still counts")
    func boundaryIsInclusive() {
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 14), guestID: guest, isSettled: false, now: now))
    }

    /// Asked once. Both a written note and a wave-off arrive here as settled.
    @Test("a settled trip is never offered again")
    func settledIsNotOffered() {
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 1), guestID: guest, isSettled: true, now: now) == false)
    }

    /// Guest side only. There is no host-side twin of this prompt here, and a
    /// host is never asked through this path to file anything about a guest.
    @Test("a stay this user was the host on is not offered")
    func hostSideIsNotOffered() {
        let asGuestSomeoneElse = stay(guestUserID: "someone-else", endedDaysAgo: 1)
        #expect(GuestNotePrompt.shouldOffer(asGuestSomeoneElse, guestID: guest, isSettled: false, now: now) == false)
    }

    @Test("a trip that never completed is not offered")
    func incompleteIsNotOffered() {
        for status: StayRequestStatus in [.pending, .offered, .accepted, .declined, .cancelled] {
            #expect(
                GuestNotePrompt.shouldOffer(
                    stay(status: status, endedDaysAgo: 1), guestID: guest, isSettled: false, now: now
                ) == false
            )
        }
    }

    @Test("a signed-out viewer is offered nothing")
    func signedOutIsNotOffered() {
        #expect(GuestNotePrompt.shouldOffer(stay(endedDaysAgo: 1), guestID: "", isSettled: false, now: now) == false)
    }

    /// A trip the nightly sweep completed carries no `completedAt`, so checkout
    /// has to stand in rather than the prompt silently never appearing.
    @Test("a trip with no completion timestamp falls back to checkout")
    func fallsBackToCheckout() {
        var swept = stay(endedDaysAgo: 1)
        swept.completedAt = nil
        #expect(GuestNotePrompt.shouldOffer(swept, guestID: guest, isSettled: false, now: now))

        var old = stay(endedDaysAgo: 90)
        old.completedAt = nil
        #expect(GuestNotePrompt.shouldOffer(old, guestID: guest, isSettled: false, now: now) == false)
    }
}

// MARK: - The repository seam

@Suite("Guest note repository")
struct GuestNoteRepositoryTests {
    private let guest = "guest-1"
    private let host = "host-1"
    private let listing = "listing-1"

    @Test("a note written for one guest is not in another guest's collection")
    func notesAreScopedToTheirAuthor() async throws {
        let repo = InMemoryGuestNoteRepository()
        try await repo.createNote(guestID: guest, note("n1", type: .host, about: host))

        #expect(repo.notesByGuest[guest]?.count == 1)
        #expect(repo.notesByGuest["guest-2"] == nil)
    }

    @Test("an edit replaces the text and can clear the stay link")
    func editReplacesText() async throws {
        let repo = InMemoryGuestNoteRepository()
        let id = try await repo.createNote(
            guestID: guest,
            note("n1", type: .listing, about: listing, stay: "stay-1")
        )

        try await repo.updateNote(guestID: guest, noteID: id, text: "Revised", stayRequestID: nil)

        let stored = repo.notesByGuest[guest]?[id]
        #expect(stored?.text == "Revised")
        #expect(stored?.stayRequestID == nil)
        // The subject is never part of an edit; the rules refuse a note
        // re-pointed at somebody else, and the repository never offers it.
        #expect(stored?.subjectType == .listing)
        #expect(stored?.subjectID == listing)
    }

    @Test("deleting removes the note")
    func deleteRemoves() async throws {
        let repo = InMemoryGuestNoteRepository()
        let id = try await repo.createNote(guestID: guest, note("n1", type: .host, about: host))

        try await repo.deleteNote(guestID: guest, noteID: id)

        #expect(repo.notesByGuest[guest]?.isEmpty == true)
    }

    @Test("marking a prompt seen records that trip and no other")
    func promptMarker() async throws {
        let repo = InMemoryGuestNoteRepository()
        try await repo.markPromptSeen(guestID: guest, stayRequestID: "stay-1")

        #expect(repo.promptsByGuest[guest] == ["stay-1"])
        #expect(repo.promptsByGuest["guest-2"] == nil)
    }

    /// The prompt asks once. Both ways of answering it — writing something, or
    /// waving it off — have to leave the same mark, or the guest gets asked again
    /// about a trip they already wrote a note for.
    @Test("both answers to the prompt leave the same mark")
    func bothAnswersSettleThePrompt() async throws {
        let repo = InMemoryGuestNoteRepository()

        try await repo.createNote(
            guestID: guest,
            note("n1", type: .listing, about: listing, stay: "trip-written")
        )
        try await repo.markPromptSeen(guestID: guest, stayRequestID: "trip-written")
        try await repo.markPromptSeen(guestID: guest, stayRequestID: "trip-waved-off")

        #expect(repo.promptsByGuest[guest] == ["trip-written", "trip-waved-off"])
        // Waving one off writes no note. Silence is not a record of anything.
        #expect(repo.notesByGuest[guest]?.values.contains { $0.stayRequestID == "trip-waved-off" } == false)
    }
}

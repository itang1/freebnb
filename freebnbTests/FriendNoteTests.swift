//
//  FriendNoteTests.swift
//  freebnbTests
//
//  The pure half of private notes, plus the repository seam.
//
//  The half that actually enforces the promise is `firestore.rules`
//  (rules-tests/friend_notes.test.mjs): nothing in this file can stop a friend
//  reading a note, and nothing here should be read as though it could. What is
//  tested here is the part the client owns — ordering, normalization, and the
//  "ask once" arithmetic behind the post-stay prompt.
//
//  `FriendNoteStore` itself binds its host id from an Auth state listener and so
//  is not directly constructible under test, exactly as `CircleStore` is not;
//  its pure inputs and its repository are covered instead.
//

import Foundation
import Testing
@testable import freebnb

private func note(
    _ id: String,
    about subject: String = "friend-1",
    text: String = "Left the place spotless.",
    stay: String? = nil,
    created: Date? = nil,
    updated: Date? = nil
) -> FriendNote {
    FriendNote(
        id: id,
        subjectUserID: subject,
        text: text,
        stayRequestID: stay,
        createdAt: created,
        updatedAt: updated
    )
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 86_400 * Double(n)) }

// MARK: - The model

@Suite("Friend note text")
struct FriendNoteTextTests {
    @Test("whitespace-only text is nothing to save")
    func blankIsNil() {
        #expect(FriendNote.normalized("   \n\t ") == nil)
        #expect(FriendNote.normalized("") == nil)
    }

    @Test("text is trimmed rather than stored with its edges")
    func trims() {
        #expect(FriendNote.normalized("  kept the cat alive  ") == "kept the cat alive")
    }

    /// The cap exists in three places — here, `firestore.rules`, and the
    /// composer's character counter. The client cutting to it is what keeps an
    /// over-long note a field error instead of a permission denial.
    @Test("text is cut to the cap the rules enforce")
    func clampsToCap() {
        let long = String(repeating: "x", count: FriendNote.maxLength + 500)
        #expect(FriendNote.normalized(long)?.count == FriendNote.maxLength)
    }
}

@Suite("Friend note ordering")
struct FriendNoteOrderingTests {
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

    @Test("notes about one friend exclude everyone else's")
    func filtersBySubject() {
        let all = [
            note("a", about: "friend-1", created: day(1)),
            note("b", about: "friend-2", created: day(2)),
            note("c", about: "friend-1", created: day(3))
        ]
        #expect(all.about("friend-1").map(\.id) == ["c", "a"])
        #expect(all.about("friend-2").map(\.id) == ["b"])
        #expect(all.about("nobody").isEmpty)
    }

    /// Both timestamps are server-stamped in one commit on create, so they land
    /// close together but not identical; "edited" has to mean a real later edit.
    @Test("a note is only 'edited' once it has actually been revised")
    func editedFlag() {
        #expect(note("a", created: day(1), updated: day(1)).wasEdited == false)
        #expect(note("b", created: day(1), updated: day(1).addingTimeInterval(0.4)).wasEdited == false)
        #expect(note("c", created: day(1), updated: day(2)).wasEdited)
        // A note whose timestamps haven't come back yet has not been edited.
        #expect(note("d", created: nil, updated: nil).wasEdited == false)
    }
}

// MARK: - The post-stay prompt

@Suite("Friend note post-stay prompt")
struct FriendNotePromptTests {
    private let host = "host-1"
    private let guest = "friend-1"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stay(
        status: StayRequestStatus = .completed,
        hostUserID: String? = nil,
        endedDaysAgo: Double
    ) -> StayRequest {
        let ended = now.addingTimeInterval(-endedDaysAgo * 86_400)
        return StayRequest(
            listingID: "listing-1",
            listingCity: "Town",
            listingHostName: "Host",
            hostUserID: hostUserID ?? host,
            guestUserID: guest,
            checkIn: ended.addingTimeInterval(-2 * 86_400),
            checkOut: ended,
            status: status,
            completedAt: ended
        )
    }

    @Test("a stay that just ended is offered")
    func recentStayIsOffered() {
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 1), hostID: host, isSettled: false, now: now))
    }

    /// The reason the window exists: shipping this must not greet a host with a
    /// prompt for every stay they have ever hosted.
    @Test("a stay from long ago is not offered")
    func oldStayIsNotOffered() {
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 400), hostID: host, isSettled: false, now: now) == false)
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 15), hostID: host, isSettled: false, now: now) == false)
    }

    @Test("the window's last day still counts")
    func boundaryIsInclusive() {
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 14), hostID: host, isSettled: false, now: now))
    }

    /// Asked once. Both a written note and a wave-off arrive here as settled.
    @Test("a settled stay is never offered again")
    func settledIsNotOffered() {
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 1), hostID: host, isSettled: true, now: now) == false)
    }

    /// Host side only. There is no guest-side twin of this prompt anywhere in
    /// the feature, and a guest must never be asked to file anything about the
    /// person who put them up.
    @Test("a stay this user was the guest on is not offered")
    func guestSideIsNotOffered() {
        let hostedByOther = stay(hostUserID: "someone-else", endedDaysAgo: 1)
        #expect(FriendNotePrompt.shouldOffer(hostedByOther, hostID: host, isSettled: false, now: now) == false)
    }

    @Test("a stay that never completed is not offered")
    func incompleteIsNotOffered() {
        for status: StayRequestStatus in [.pending, .offered, .accepted, .declined, .cancelled] {
            #expect(
                FriendNotePrompt.shouldOffer(
                    stay(status: status, endedDaysAgo: 1), hostID: host, isSettled: false, now: now
                ) == false
            )
        }
    }

    @Test("a signed-out viewer is offered nothing")
    func signedOutIsNotOffered() {
        #expect(FriendNotePrompt.shouldOffer(stay(endedDaysAgo: 1), hostID: "", isSettled: false, now: now) == false)
    }

    /// A stay the nightly sweep completed carries no `completedAt`, so checkout
    /// has to stand in rather than the prompt silently never appearing.
    @Test("a stay with no completion timestamp falls back to checkout")
    func fallsBackToCheckout() {
        var swept = stay(endedDaysAgo: 1)
        swept.completedAt = nil
        #expect(FriendNotePrompt.shouldOffer(swept, hostID: host, isSettled: false, now: now))

        var old = stay(endedDaysAgo: 90)
        old.completedAt = nil
        #expect(FriendNotePrompt.shouldOffer(old, hostID: host, isSettled: false, now: now) == false)
    }
}

// MARK: - The repository seam

@Suite("Friend note repository")
struct FriendNoteRepositoryTests {
    private let host = "host-1"
    private let friend = "friend-1"

    @Test("a note written for one host is not in another host's collection")
    func notesAreScopedToTheirAuthor() async throws {
        let repo = InMemoryFriendNoteRepository()
        try await repo.createNote(hostID: host, note("n1", about: friend))

        #expect(repo.notesByHost[host]?.count == 1)
        #expect(repo.notesByHost["host-2"] == nil)
    }

    @Test("an edit replaces the text and can clear the stay link")
    func editReplacesText() async throws {
        let repo = InMemoryFriendNoteRepository()
        let id = try await repo.createNote(hostID: host, note("n1", about: friend, stay: "stay-1"))

        try await repo.updateNote(hostID: host, noteID: id, text: "Revised", stayRequestID: nil)

        let stored = repo.notesByHost[host]?[id]
        #expect(stored?.text == "Revised")
        #expect(stored?.stayRequestID == nil)
        // The subject is never part of an edit; the rules refuse a note
        // re-pointed at somebody else, and the repository never offers it.
        #expect(stored?.subjectUserID == friend)
    }

    @Test("deleting removes the note")
    func deleteRemoves() async throws {
        let repo = InMemoryFriendNoteRepository()
        let id = try await repo.createNote(hostID: host, note("n1", about: friend))

        try await repo.deleteNote(hostID: host, noteID: id)

        #expect(repo.notesByHost[host]?.isEmpty == true)
    }

    @Test("marking a prompt seen records that stay and no other")
    func promptMarker() async throws {
        let repo = InMemoryFriendNoteRepository()
        try await repo.markPromptSeen(hostID: host, stayRequestID: "stay-1")

        #expect(repo.promptsByHost[host] == ["stay-1"])
        #expect(repo.promptsByHost["host-2"] == nil)
    }

    /// The prompt asks once. Both ways of answering it — writing something, or
    /// waving it off — have to leave the same mark, or the host gets asked
    /// again about a stay they already wrote a note for.
    @Test("both answers to the prompt leave the same mark")
    func bothAnswersSettleThePrompt() async throws {
        let repo = InMemoryFriendNoteRepository()

        try await repo.createNote(hostID: host, note("n1", about: friend, stay: "stay-written"))
        try await repo.markPromptSeen(hostID: host, stayRequestID: "stay-written")
        try await repo.markPromptSeen(hostID: host, stayRequestID: "stay-waved-off")

        #expect(repo.promptsByHost[host] == ["stay-written", "stay-waved-off"])
        // Waving one off writes no note. Silence is not a record of anything.
        #expect(repo.notesByHost[host]?.values.contains { $0.stayRequestID == "stay-waved-off" } == false)
    }
}

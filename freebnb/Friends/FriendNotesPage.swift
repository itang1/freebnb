//
//  FriendNotesPage.swift
//  freebnb
//
//  Where a host reads and writes their private notes about one friend.
//
//  Every screen in this file is the host's own, in the same sense CirclesPage
//  is: nothing here is reachable from a listing, a conversation, or any surface
//  a guest can open, and no note is ever rendered for anybody but its author.
//  The copy says so plainly and exactly once per screen, because a host who is
//  unsure who can see this writes a note they'd have written for an audience,
//  which is the wrong note.
//
//  There is no rating, no count, and no summary here on purpose. A note is
//  something the host reads and then decides for themselves.
//

import SwiftUI

struct FriendNotesPage: View {
    let friendID: String
    let friendName: String

    @Environment(FriendNoteStore.self) private var noteStore

    @State private var composing: FriendNoteComposition?
    @State private var pendingDeletion: FriendNote?
    @State private var actionError: String?

    private var notes: [FriendNote] { noteStore.notes(about: friendID) }

    var body: some View {
        List {
            if let actionError {
                Section { InlineErrorLabel(message: actionError) }
            }

            Section {
                Button {
                    composing = .new(friendID: friendID, stayRequestID: nil)
                } label: {
                    Label("Add a note", systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Only you can read these. \(friendName) is never told a note exists, and nothing here changes what they can book.")
            }

            if notes.isEmpty {
                Section {
                    Text("""
                    Nothing yet. Notes are for the things you'd want to remember about \
                    staying with \(friendName), or hosting them, months from now.
                    """)
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
            } else {
                Section("Your notes") {
                    ForEach(notes) { note in
                        FriendNoteRow(note: note)
                            .contentShape(Rectangle())
                            .onTapGesture { composing = .editing(note) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = note
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    composing = .editing(note)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Color.accent)
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Notes on \(friendName)")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $composing) { composition in
            FriendNoteComposerSheet(composition: composition, friendName: friendName)
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let note = pendingDeletion { Task { await delete(note) } }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
    }

    private func delete(_ note: FriendNote) async {
        pendingDeletion = nil
        actionError = nil
        do { try await noteStore.deleteNote(note) }
        catch { actionError = error.localizedDescription }
    }
}

// MARK: - One note

private struct FriendNoteRow: View {
    let note: FriendNote

    @Environment(StayRequestStore.self) private var requestStore

    /// The stay this note was written about, when it was written about one and
    /// that stay is still in the store. A note outlives the record it was filed
    /// under, so a missing stay drops the subtitle rather than the note.
    private var stayContext: String? {
        guard let stayRequestID = note.stayRequestID else { return nil }
        let known = requestStore.incomingRequests + requestStore.outgoingRequests
        guard let stay = known.first(where: { $0.id == stayRequestID }) else { return nil }
        return "\(stay.listingLabel) · \(stay.dateRangeText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let createdAt = note.createdAt {
                    Text(AppDateFormatters.mediumDate.string(from: createdAt))
                }
                if note.wasEdited {
                    Text("· edited")
                }
                if let stayContext {
                    Text("· \(stayContext)")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundColor(.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Composer

/// What the composer was opened for. Modelled as one value rather than a pair of
/// optionals so "editing a note" and "writing a new one about a stay" cannot be
/// half-set at the same time.
enum FriendNoteComposition: Identifiable, Hashable {
    case new(friendID: String, stayRequestID: String?)
    case editing(FriendNote)

    var id: String {
        switch self {
        case .new(let friendID, let stayRequestID): return "new-\(friendID)-\(stayRequestID ?? "")"
        case .editing(let note): return "edit-\(note.id ?? "")"
        }
    }

    var existingText: String {
        switch self {
        case .new: return ""
        case .editing(let note): return note.text
        }
    }
}

struct FriendNoteComposerSheet: View {
    let composition: FriendNoteComposition
    let friendName: String

    @Environment(FriendNoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmed.isEmpty && trimmed.count <= FriendNote.maxLength && !isSaving
    }

    private var isEditing: Bool {
        if case .editing = composition { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to remember?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .disabled(isSaving)
                } header: {
                    Text("Private note")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // The one thing worth saying at the moment of writing,
                        // said once. A host who has to guess at the audience
                        // writes for one.
                        Text("Only you will ever read this. \(friendName) isn't told, and it doesn't affect anything they can book.")
                        Text("\(trimmed.count) / \(FriendNote.maxLength)")
                            .foregroundColor(trimmed.count > FriendNote.maxLength ? .danger : .secondaryText)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.danger)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit note" : "Note on \(friendName)")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.callToAction)
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear { text = composition.existingText }
            .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch composition {
            case .new(let friendID, let stayRequestID):
                try await noteStore.addNote(about: friendID, text: trimmed, stayRequestID: stayRequestID)
            case .editing(let note):
                try await noteStore.updateNote(note, text: trimmed)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Entry point

/// The row that takes a host from a friend's screen into their notes, carrying
/// a one-line preview of the most recent one. Used on both host-side friend
/// screens so the entry point reads the same in each.
struct FriendNotesLink: View {
    let friendID: String
    let friendName: String

    @Environment(FriendNoteStore.self) private var noteStore

    private var mostRecent: FriendNote? { noteStore.mostRecentNote(about: friendID) }

    var body: some View {
        NavigationLink {
            FriendNotesPage(friendID: friendID, friendName: friendName)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private notes")
                    // The preview is the note itself, not a count dressed up as
                    // a verdict: "3 notes" invites a host to read a number where
                    // the point is to read the sentence they wrote.
                    Text(mostRecent?.text ?? "Just for you. \(friendName) never sees these.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: mostRecent == nil ? "square.and.pencil" : "note.text")
                    .foregroundColor(Color.accent)
            }
        }
    }
}

/// The optional add-a-note moment, as a section the Stays tab drops into its
/// own list: an ordinary row, offered once per stay, dismissible, and never a
/// modal standing between the host and the rest of the screen. If they ignore it
/// forever, nothing happens; if they wave it off, it does not come back, and
/// they can still write a note from that friend's screen whenever they like.
///
/// Which stays reach it is the caller's question (`FriendNotePrompt`); what it
/// says and how hard it asks are this file's.
struct NotePromptSection: View {
    let stays: [StayRequest]
    @Binding var composing: FriendNoteComposition?

    @Environment(FriendNoteStore.self) private var noteStore
    @Environment(UserProfileStore.self) private var userProfileStore

    var body: some View {
        if !stays.isEmpty {
            Section {
                ForEach(stays, id: \.id) { stay in
                    NotePromptRow(
                        guestName: userProfileStore.displayName(for: stay.guestUserID) ?? "FreeBNB User",
                        dateRange: stay.dateRangeText,
                        onAdd: {
                            composing = .new(friendID: stay.guestUserID, stayRequestID: stay.id)
                        },
                        onDismiss: {
                            Task { await noteStore.dismissPrompt(forStayRequestID: stay.id) }
                        }
                    )
                }
            } header: {
                Text("Anything to remember?")
            } footer: {
                Text("""
                A note for yourself, if it's useful. Nobody else ever reads it, \
                and skipping is the same as writing nothing.
                """)
            }
        }
    }
}

/// One stay's prompt. Two plain choices, neither of them urgent: the ask is an
/// offer, so "Not this time" is a real answer and is styled as one rather than
/// as a dismissal the host has to hunt for.
private struct NotePromptRow: View {
    let guestName: String
    let dateRange: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(guestName) stayed with you")
                    .font(.subheadline.weight(.medium))
                Text(dateRange)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            HStack(spacing: 12) {
                Button(action: onAdd) {
                    Label("Add a private note", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Color.accent.opacity(0.12), in: Capsule())
                        .foregroundColor(Color.accent)
                }
                .buttonStyle(.plain)

                Button("Not this time", action: onDismiss)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        FriendNotesPage(friendID: PreviewData.friendID, friendName: "Maya")
            .previewEnvironment()
    }
}

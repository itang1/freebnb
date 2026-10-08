//
//  FriendNotesPage.swift
//  freebnb
//
//  Where a host reads and writes private notes about one friend. Every screen is the
//  host's own (like CirclesPage): nothing is reachable by a guest and no note renders
//  for anyone but its author. The copy says so once per screen, since a host unsure
//  of the audience writes the wrong note. No rating, count or summary, on purpose.
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

    /// The stay this note was about, if still in the store; a missing stay drops the subtitle, not the note.
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

/// What the composer opened for: one value, so "editing" and "new note about a stay" can't be half-set.
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
                        // The audience, said once; a host who has to guess writes for one.
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

/// The row from a friend's screen into their notes, with a one-line preview of the latest; used on both
/// host-side friend screens.
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
                    // The preview is the note itself, not a count, which would invite reading a number over
                    // the sentence.
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

/// The optional add-a-note moment as a Stays tab section: an ordinary row, offered
/// once per stay, dismissible, never a modal. Ignoring it does nothing and waving it
/// off is permanent; notes remain writable from the friend's screen. `FriendNotePrompt`
/// picks the stays.
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

/// One stay's prompt: two plain choices, and "Not this time" is a real answer, not a hidden dismissal.
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

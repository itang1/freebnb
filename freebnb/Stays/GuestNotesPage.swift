//
//  GuestNotesPage.swift
//  freebnb
//
//  Where a guest reads and writes private notes about one host or listing. Every
//  screen here is the guest's own (like `FriendNotesPage` for hosts): nothing is
//  reachable from the host's side, and the copy says so once per screen, since a
//  guest unsure of the audience writes the wrong note. There is deliberately no
//  rating, count, summary or report path; reporting lives on the profile and listing pages.
//

import SwiftUI

struct GuestNotesPage: View {
    let subjectType: GuestNoteSubjectType
    let subjectID: String
    /// The host's name or the listing's label, for copy and title.
    let subjectName: String

    @Environment(GuestNoteStore.self) private var noteStore

    @State private var composing: GuestNoteComposition?
    @State private var pendingDeletion: GuestNote?
    @State private var actionError: String?

    private var notes: [GuestNote] { noteStore.notes(about: subjectType, subjectID) }

    /// What a note is about, mid-sentence: "staying with Maya" or "this listing".
    private var aboutPhrase: String {
        switch subjectType {
        case .host:    return "staying with \(subjectName)"
        case .listing: return "this listing"
        }
    }

    var body: some View {
        List {
            if let actionError {
                Section { InlineErrorLabel(message: actionError) }
            }

            Section {
                Button {
                    composing = .new(subjectType: subjectType, subjectID: subjectID, stayRequestID: nil)
                } label: {
                    Label("Add a note", systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Only you can read these. \(subjectName) is never told a note exists, and nothing here is sent to anyone.")
            }

            if notes.isEmpty {
                Section {
                    Text("Nothing yet. Notes are for the things you'd want to remember about \(aboutPhrase), months from now.")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
            } else {
                Section("Your notes") {
                    ForEach(notes) { note in
                        GuestNoteRow(note: note)
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
        .navigationTitle("Notes on \(subjectName)")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $composing) { composition in
            GuestNoteComposerSheet(composition: composition, subjectName: subjectName)
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

    private func delete(_ note: GuestNote) async {
        pendingDeletion = nil
        actionError = nil
        do { try await noteStore.deleteNote(note) }
        catch { actionError = error.localizedDescription }
    }
}

// MARK: - One note

private struct GuestNoteRow: View {
    let note: GuestNote

    @Environment(StayRequestStore.self) private var requestStore

    /// The trip this note was about, if still in the store; a missing stay drops the subtitle, not the note.
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

/// What the composer opened for: one value, so "editing" and "new note about a trip" can't be half-set.
enum GuestNoteComposition: Identifiable, Hashable {
    case new(subjectType: GuestNoteSubjectType, subjectID: String, stayRequestID: String?)
    case editing(GuestNote)

    var id: String {
        switch self {
        case .new(let type, let subjectID, let stayRequestID):
            return "new-\(type.rawValue)-\(subjectID)-\(stayRequestID ?? "")"
        case .editing(let note):
            return "edit-\(note.id ?? "")"
        }
    }

    var existingText: String {
        switch self {
        case .new: return ""
        case .editing(let note): return note.text
        }
    }
}

struct GuestNoteComposerSheet: View {
    let composition: GuestNoteComposition
    let subjectName: String

    @Environment(GuestNoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmed.isEmpty && trimmed.count <= GuestNote.maxLength && !isSaving
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
                        // The audience, said once; a guest who has to guess writes for one.
                        Text("Only you will ever read this. \(subjectName) isn't told, and it isn't sent to anyone.")
                        Text("\(trimmed.count) / \(GuestNote.maxLength)")
                            .foregroundColor(trimmed.count > GuestNote.maxLength ? .danger : .secondaryText)
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
            .navigationTitle(isEditing ? "Edit note" : "Note on \(subjectName)")
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
            case .new(let type, let subjectID, let stayRequestID):
                try await noteStore.addNote(about: type, subjectID, text: trimmed, stayRequestID: stayRequestID)
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

/// The button from a host's profile or a listing into the guest's private notes,
/// with a one-line preview of the latest. Quietest control on the page (grey, not
/// accent): private shouldn't look like an invitation to broadcast.
struct GuestNotesLink: View {
    let subjectType: GuestNoteSubjectType
    let subjectID: String
    let subjectName: String

    @Environment(GuestNoteStore.self) private var noteStore

    private var mostRecent: GuestNote? { noteStore.mostRecentNote(about: subjectType, subjectID) }

    /// A short "never sees these" line right for the subject; a listing has no one to tell, its host does.
    private var reassurance: String {
        switch subjectType {
        case .host:    return "Just for you. \(subjectName) never sees these."
        case .listing: return "Just for you. Nobody else ever sees these."
        }
    }

    var body: some View {
        NavigationLink {
            GuestNotesPage(subjectType: subjectType, subjectID: subjectID, subjectName: subjectName)
        } label: {
            Label("Your private notes", systemImage: mostRecent == nil ? "note.text" : "note.text")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.secondaryText.opacity(0.10))
                .foregroundColor(.secondaryText)
                .cornerRadius(10)
        }
        .buttonStyle(.pressable)
        .accessibilityHint(mostRecent?.text ?? reassurance)
    }
}

// MARK: - Post-trip prompt

/// The optional add-a-note moment as a Stays tab section: an ordinary row, offered
/// once per trip, dismissible, never a modal. Ignoring it does nothing and waving
/// it off is permanent; notes remain writable from the host or listing screen.
/// Mirrors the host's `NotePromptSection`; `GuestNotePrompt` picks the trips. The
/// note is filed against the trip's listing, with the stay kept as context (`stayRequestID`).
struct GuestNotePromptSection: View {
    let stays: [StayRequest]
    @Binding var composing: GuestNoteComposition?

    @Environment(GuestNoteStore.self) private var noteStore

    var body: some View {
        if !stays.isEmpty {
            Section {
                ForEach(stays, id: \.id) { stay in
                    GuestNotePromptRow(
                        hostName: stay.listingHostName,
                        dateRange: stay.dateRangeText,
                        onAdd: {
                            composing = .new(
                                subjectType: .listing,
                                subjectID: stay.listingID,
                                stayRequestID: stay.id
                            )
                        },
                        onDismiss: {
                            Task { await noteStore.dismissPrompt(forStayRequestID: stay.id) }
                        }
                    )
                }
            } header: {
                Text("Anything to remember?")
            } footer: {
                Text("A note for yourself, if it's useful. Nobody else ever reads it, and skipping is the same as writing nothing.")
            }
        }
    }
}

/// One trip's prompt: two plain choices, and "Not this time" is a real answer, not a hidden dismissal.
private struct GuestNotePromptRow: View {
    let hostName: String
    let dateRange: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("You stayed with \(hostName)")
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
        GuestNotesPage(subjectType: .host, subjectID: PreviewData.friendID, subjectName: "Maya")
            .previewEnvironment()
    }
}

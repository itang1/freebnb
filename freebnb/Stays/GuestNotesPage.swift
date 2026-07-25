//
//  GuestNotesPage.swift
//  freebnb
//
//  Where a guest reads and writes their private notes about one host or one
//  listing.
//
//  Every screen in this file is the guest's own, in the same sense
//  `FriendNotesPage` is the host's: nothing here is reachable from a screen the
//  host can open, and no note is ever rendered for anybody but its author. The
//  copy says so plainly and exactly once per screen, because a guest who is
//  unsure who can see this writes a note they'd have written for an audience,
//  which is the wrong note.
//
//  There is no rating, no count, no summary, and no path to a report here on
//  purpose. A note is something the guest reads and then decides for themselves;
//  reporting a host is a separate, deliberate action that lives on the profile
//  and listing pages, and this is not it.
//

import SwiftUI

struct GuestNotesPage: View {
    let subjectType: GuestNoteSubjectType
    let subjectID: String
    /// The host's name or the listing's label, for the copy and the title.
    let subjectName: String

    @Environment(GuestNoteStore.self) private var noteStore

    @State private var composing: GuestNoteComposition?
    @State private var pendingDeletion: GuestNote?
    @State private var actionError: String?

    private var notes: [GuestNote] { noteStore.notes(about: subjectType, subjectID) }

    /// What a note here is about, in a form that fits mid-sentence: "staying with
    /// Maya" for a host, "this listing" for a listing. Keeps the copy honest
    /// about which of the two kinds of note the guest is writing.
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

    /// The trip this note was written about, when it was written about one and
    /// that trip is still in the store. A note outlives the record it was filed
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

/// What the composer was opened for. Modelled as one value rather than a set of
/// optionals so "editing a note" and "writing a new one about a trip" cannot be
/// half-set at the same time.
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
                        // The one thing worth saying at the moment of writing,
                        // said once. A guest who has to guess at the audience
                        // writes for one.
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

/// The button that takes a guest from a host's profile or a listing into their
/// private notes about it, carrying a one-line preview of the most recent one.
/// Styled as the quietest control on whatever page it sits on — grey rather than
/// accent — because what is private should not look like an invitation to
/// broadcast, and because the loud controls on those pages reach the other
/// person while this one never does.
struct GuestNotesLink: View {
    let subjectType: GuestNoteSubjectType
    let subjectID: String
    let subjectName: String

    @Environment(GuestNoteStore.self) private var noteStore

    private var mostRecent: GuestNote? { noteStore.mostRecentNote(about: subjectType, subjectID) }

    /// A short "never sees these" line, correct for whichever kind of subject
    /// this is. A listing has no one to be told; its host does.
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

/// The optional add-a-note moment on the guest's side, as a section the Stays
/// tab drops into its own list: an ordinary row, offered once per trip,
/// dismissible, and never a modal standing between the guest and the rest of the
/// screen. If they ignore it forever, nothing happens; if they wave it off, it
/// does not come back, and they can still write a note from the host's or
/// listing's screen whenever they like.
///
/// The mirror of the host's `NotePromptSection`. Which trips reach it is the
/// caller's question (`GuestNotePrompt`); what it says and how hard it asks are
/// this file's — which is to say, softly, because the ask is an offer.
///
/// The note it writes is filed against the listing the trip was at, so it has a
/// home the guest can find it in again — the same listing page the standing
/// entry point sits on. That the stay was with a particular host is context the
/// note keeps (`stayRequestID`), not a second place to store it.
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

/// One trip's prompt. Two plain choices, neither of them urgent: the ask is an
/// offer, so "Not this time" is a real answer and is styled as one rather than
/// as a dismissal the guest has to hunt for.
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

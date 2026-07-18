//
//  WriteReferenceSheet.swift
//  freebnb
//
//  A friend vouching for a friend (feature 1). Only offered when an accepted
//  friend edge exists — `firestore.rules` refuses the write otherwise, so the
//  button's absence and the rule agree rather than the UI merely hiding it.
//

import SwiftUI

struct WriteReferenceSheet: View {
    let subjectUserID: String
    let subjectName: String
    /// The reference this friend already wrote, if any: the sheet edits it in
    /// place rather than silently overwriting it.
    let existing: CharacterReference?

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        !trimmed.isEmpty && trimmed.count <= CharacterReference.maxLength && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should people know about \(subjectName)?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .disabled(isSubmitting)
                } header: {
                    Text("Your reference")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // Says which of the two trust surfaces this is, at the
                        // moment somebody is writing one.
                        Text("A reference vouches for \(subjectName) as a guest, a host, or both. It carries no rating: reviews come from stays that actually happened.")
                        Text("Shown publicly on \(subjectName)'s profile, with your name.")
                        Text("\(trimmed.count) / \(CharacterReference.maxLength)")
                            .foregroundColor(trimmed.count > CharacterReference.maxLength ? .red : .secondary)
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
            .navigationTitle(existing == nil ? "Vouch for \(subjectName)" : "Edit reference")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Post") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { text = existing?.text ?? "" }
            .disabled(isSubmitting)
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await reviewStore.submitReference(
                CharacterReference(
                    authorUserID: authManager.userID,
                    subjectUserID: subjectUserID,
                    text: trimmed
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    WriteReferenceSheet(
        subjectUserID: PreviewData.friendID,
        subjectName: "Maya",
        existing: nil
    )
    .previewEnvironment()
}

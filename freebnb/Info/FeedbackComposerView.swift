//
//  FeedbackComposerView.swift
//  freebnb
//
//  The in-app feedback composer (feature 43). Posts a note to the Google Form in
//  `FeedbackService`, whose responses feed the team's spreadsheet. Anyone can
//  send, guests included, since the Form needs no account; the sender's ID rides
//  along when they are signed in. The same form is public on the web.
//

import SwiftUI

struct FeedbackComposerView: View {
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var draft = FeedbackDraft()
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didSend = false

    var body: some View {
        NavigationStack {
            Group {
                if didSend {
                    sentConfirmation
                } else {
                    composer
                }
            }
            .background(Color.primaryBackground.ignoresSafeArea())
            .navigationTitle("Send Feedback")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isSending)
                }
                if !didSend {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { Task { await send() } }
                            .disabled(!draft.isValid || isSending)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        Form {
            Section {
                TextField(
                    "A problem, something you loved, a feature you want, anything.",
                    text: $draft.message,
                    axis: .vertical
                )
                .lineLimit(5...12)
                .disabled(isSending)
            } footer: {
                HStack {
                    Text("Your app version is attached to help us track down issues.")
                    Spacer()
                    Text("\(draft.remainingCharacters)")
                        .monospacedDigit()
                        .foregroundColor(draft.remainingCharacters < 0 ? .red : .secondary)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                    Button("Open the feedback form in your browser") {
                        openURL(FeedbackForm.webURL)
                    }
                }
            }
        }
    }

    // MARK: - Sent confirmation

    private var sentConfirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Thanks for the feedback")
                .font(.title3.weight(.semibold))
            Text("We read every note. If it needs a reply, we'll be in touch.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accent)
                    .foregroundColor(.onAccent)
                    .cornerRadius(12)
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Send

    private func send() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await userProfileStore.submitFeedback(message: draft.message)
            didSend = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    FeedbackComposerView()
        .previewEnvironment()
}

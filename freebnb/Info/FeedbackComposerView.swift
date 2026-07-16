//
//  FeedbackComposerView.swift
//  freebnb
//
//  The in-app feedback composer (feature 43). Posts a note to the Google Form in
//  `FeedbackService`, whose responses feed the team's spreadsheet. The button is
//  gated behind a full account as a product choice, so a note carries an ID we
//  can reply to; the same form is public on the web for anyone else.
//

import SwiftUI

struct FeedbackComposerView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var draft = FeedbackDraft()
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didSend = false

    private var isGuest: Bool { authManager.authMethod == .guest }

    var body: some View {
        NavigationStack {
            Group {
                if didSend {
                    sentConfirmation
                } else if isGuest {
                    guestGate
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
                if !didSend && !isGuest {
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
                    Text("Your account and app version are attached so we can follow up.")
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

    // MARK: - Guest gate

    private var guestGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Create an account to send feedback")
                .font(.headline)
            Text("Feedback is tied to your account so we can reply and fix what you flag.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
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

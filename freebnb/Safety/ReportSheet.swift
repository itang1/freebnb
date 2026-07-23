//
//  ReportSheet.swift
//  freebnb
//

import SwiftUI

struct ReportSheet: View {
    enum TargetType: String {
        case user = "user"
        case listing = "listing"
        case message = "message"
    }

    let targetType: TargetType
    let targetID: String
    let targetName: String

    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    private var reasonTrimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Matches the `reason` cap in `firestore.rules`. Checked here so an
    /// over-long report is a visible counter rather than a permission denial
    /// after the fact — a report that bounces at the server reads as the app
    /// refusing to hear it, which is the last thing this sheet should do.
    private static let reasonMaxLength = 2000
    private var reasonTooLong: Bool { reasonTrimmed.count > Self.reasonMaxLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Reporting: \(targetName)")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }

                Section {
                    TextEditor(text: $reason)
                        .frame(minHeight: 100)
                        .disabled(isSubmitting || submitted)
                } header: {
                    Text("What's the issue?")
                } footer: {
                    if reasonTooLong {
                        Text("\(reasonTrimmed.count) / \(Self.reasonMaxLength)")
                            .foregroundColor(.danger)
                    }
                }

                if let errorMessage {
                    Section { InlineErrorLabel(message: errorMessage) }
                }

                if submitted {
                    Section {
                        Label("Report submitted. Thank you.", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.success)
                    }
                }
            }
            .navigationTitle("Report \(targetType.rawValue.capitalized)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Submit") { Task { await submit() } }
                            .disabled(reasonTrimmed.isEmpty || reasonTooLong || submitted)
                    }
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        do {
            try await userProfileStore.submitReport(
                targetType: targetType.rawValue,
                targetID: targetID,
                reason: reasonTrimmed
            )
            submitted = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

#Preview {
    ReportSheet(
        targetType: .listing,
        targetID: "abc123",
        targetName: "Irene's place in Austin"
    )
    .previewEnvironment()
}

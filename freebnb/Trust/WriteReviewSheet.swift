//
//  WriteReviewSheet.swift
//  freebnb
//
//  The post-stay review form (feature 1): a rating, a public comment, and a
//  private note that only the person being reviewed will ever read.
//
//  The private channel is what makes an honest public review possible. Without
//  it, the only place to put "the shower was cold" is the profile, so people
//  either say nothing or say it in front of everyone.
//

import SwiftUI

struct WriteReviewSheet: View {
    let stay: StayRequest
    let role: ReviewRole
    let subjectName: String

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var rating = 0
    @State private var publicComment = ""
    @State private var privateNote = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var trimmedComment: String { publicComment.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNote: String { privateNote.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { Review.ratingRange.contains(rating) && !isSubmitting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subjectName)
                            .font(.headline)
                        Text("\(stay.listingCity) · \(stay.dateRangeText)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Rating") {
                    StarRatingPicker(rating: $rating)
                        .disabled(isSubmitting)
                }

                Section {
                    TextField("Optional", text: $publicComment, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(isSubmitting)
                } header: {
                    Text(role.prompt)
                } footer: {
                    Text("Shown on \(subjectName)'s profile.")
                }

                Section {
                    TextField("Optional", text: $privateNote, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(isSubmitting)
                } header: {
                    Text("Private note")
                } footer: {
                    Text("Only \(subjectName) sees this. Nobody else, ever: not on your profile, not on theirs.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Review your \(role.subjectNoun)")
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
                            .buttonStyle(.borderedProminent)
                            .tint(Color.callToAction)
                            .disabled(!canSubmit)
                    }
                }
            }
            .disabled(isSubmitting)
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let review = Review(
            stayRequestID: stay.id,
            listingID: stay.listingID,
            authorUserID: authManager.userID,
            subjectUserID: stay.otherParty(from: authManager.userID),
            role: role,
            rating: rating,
            publicComment: trimmedComment.isEmpty ? nil : trimmedComment
        )
        do {
            try await reviewStore.submitReview(review, privateFeedback: trimmedNote.isEmpty ? nil : trimmedNote)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Star picker

struct StarRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Review.ratingRange, id: \.self) { star in
                Button {
                    rating = star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundColor(star <= rating ? .orange : .secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star == rating ? [.isSelected] : [])
            }
            Spacer()
            if rating > 0 {
                Text("\(rating) / 5")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Read-only stars, for rendering a review someone already wrote.
struct StarRatingView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Review.ratingRange, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundColor(star <= rating ? .orange : .secondary.opacity(0.4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}

#Preview {
    WriteReviewSheet(stay: PreviewData.stay, role: .hostReviewingGuest, subjectName: "Maya")
        .previewEnvironment()
}

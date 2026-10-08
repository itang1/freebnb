//
//  ReviewsSection.swift
//  freebnb
//
//  Renders the reviews and character references about one person, on the profile page and the listing detail
//  page (the host's).
//

import SwiftUI

struct ReviewsSection: View {
    let subjectUserID: String
    let subjectName: String
    /// Caps how many reviews render; nil shows all (profile), a listing shows a taste.
    var limit: Int?

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(UserProfileStore.self) private var userProfileStore

    private var reviews: [Review] { reviewStore.reviews(about: subjectUserID) }
    private var shown: [Review] { limit.map { Array(reviews.prefix($0)) } ?? reviews }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reviews")
                    .font(.headline)
                Spacer()
                if let average = reviews.averageRating {
                    Text(String(format: "%.1f ★ · %d", average, reviews.count))
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
            }

            // Spells out what a review is, apart from references below: only a completed stay produces one,
            // in both directions.
            Text("From people who have actually stayed, in either direction: guests review their host; hosts review their guest.")
                .font(.caption)
                .foregroundColor(.secondaryText)

            if !reviewStore.hasLoadedReviews(about: subjectUserID) {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if reviews.isEmpty {
                Text("No reviews yet. \(subjectName) hasn't finished a stay on FreeBNB.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(shown) { review in
                    ReviewRow(review: review, authorName: authorName(review))
                }
                if reviews.count > shown.count {
                    Text("Showing \(shown.count) of \(reviews.count). See them all on \(subjectName)'s profile.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
        }
        .task { await reviewStore.loadReviews(about: subjectUserID) }
    }

    private func authorName(_ review: Review) -> String {
        userProfileStore.displayName(for: review.authorUserID) ?? "FreeBNB User"
    }
}

struct ReviewRow: View {
    let review: Review
    let authorName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                StarRatingView(rating: review.rating)
                Spacer()
                if let createdAt = review.createdAt {
                    Text(AppDateFormatters.mediumDate.string(from: createdAt))
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            if let comment = review.publicComment, !comment.isEmpty {
                Text(comment)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            // A rating with no words is still a data point; say so rather than leave a blank.
            if review.publicComment?.isEmpty ?? true {
                Text("Rated, no comment left.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondaryText.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Private feedback

/// The notes reviewers left for you alone, shown only on your own profile: the half of a review that never
/// becomes public, which makes honest public reviews possible.
struct PrivateFeedbackSection: View {
    let subjectUserID: String

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(UserProfileStore.self) private var userProfileStore

    private var notes: [(review: Review, feedback: PrivateFeedback)] {
        reviewStore.reviews(about: subjectUserID).compactMap { review in
            reviewStore.privateFeedback(reviewID: review.id).map { (review, $0) }
        }
    }

    var body: some View {
        Group {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Private feedback for you")
                        .font(.headline)
                    Text("Only you can see these. They aren't on your profile.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)

                    ForEach(notes, id: \.review.id) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                userProfileStore.displayName(for: note.review.authorUserID) ?? "FreeBNB User",
                                systemImage: "lock.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondaryText)
                            Text(note.feedback.text)
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.secondaryText.opacity(0.06))
                        .cornerRadius(10)
                    }
                }
            }
        }
        // Depends on the reviews being loaded, so it runs after ReviewsSection's own task.
        .task(id: reviewStore.reviews(about: subjectUserID).count) {
            await reviewStore.loadPrivateFeedback(for: reviewStore.reviews(about: subjectUserID))
        }
    }
}

// MARK: - References

struct ReferencesSection: View {
    let subjectUserID: String
    let subjectName: String

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(AuthManager.self) private var authManager

    @State private var deleteError: String?

    private var references: [CharacterReference] { reviewStore.references(about: subjectUserID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("References from friends")
                .font(.headline)

            // A reference is a vouch from someone who hasn't stayed, so it carries no rating and can speak to
            // either side of a future stay.
            Text("Vouches from friends who haven't stayed with \(subjectName), speaking to them as a guest, a host, or both.")
                .font(.caption)
                .foregroundColor(.secondaryText)

            if !reviewStore.hasLoadedReferences(about: subjectUserID) {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if references.isEmpty {
                Text("No references yet. Friends of \(subjectName) can vouch for them here.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(references) { reference in
                    ReferenceRow(
                        reference: reference,
                        authorName: userProfileStore.displayName(for: reference.authorUserID) ?? "FreeBNB User",
                        // A reference sits on your profile; you may remove one you didn't ask for, and its
                        // author may retract it.
                        canDelete: authManager.userID == reference.authorUserID
                            || authManager.userID == reference.subjectUserID,
                        onDelete: {
                            Task {
                                do { try await reviewStore.deleteReference(reference) }
                                catch { deleteError = error.localizedDescription }
                            }
                        }
                    )
                }
            }
        }
        .task { await reviewStore.loadReferences(about: subjectUserID) }
        .alert("Couldn't remove reference", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            if let deleteError { Text(deleteError) }
        }
    }
}

struct ReferenceRow: View {
    let reference: CharacterReference
    let authorName: String
    var canDelete: Bool = false
    var onDelete: (() -> Void)?

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.caption)
                    .foregroundColor(Color.accent)
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if canDelete {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove reference from \(authorName)")
                }
            }
            Text(reference.text)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accent.opacity(0.06))
        .cornerRadius(10)
        .confirmationDialog(
            "Remove this reference?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { onDelete?() }
        }
    }
}

#Preview {
    List {
        ReviewsSection(subjectUserID: PreviewData.viewerID, subjectName: "Maya")
        ReviewRow(review: PreviewData.review, authorName: "Maya")
    }
    .previewEnvironment()
}

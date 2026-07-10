//
//  ReviewsRepository.swift
//  freebnb
//
//  Reviews, private feedback, character references, and the mutual-friend count
//  (features 1 and 2). Reads are one-shot rather than live: a profile's reviews
//  change on the order of once per stay, so a snapshot listener per viewed
//  profile would cost far more than it earns.
//

@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation

// Enough to fill a profile page; the tail is not worth the read cost.
private let reviewsFetchLimit = 50
private let referencesFetchLimit = 25

protocol ReviewsRepository: Sendable {
    /// Reviews written *about* `subjectUserID`, newest first.
    func fetchReviews(subjectUserID: String) async throws -> [Review]
    /// Reviews `authorUserID` has written. Used to know which completed stays
    /// still owe a review.
    func fetchReviewsWritten(byUserID authorUserID: String) async throws -> [Review]
    /// Creates or revises the caller's review of a stay, and writes the private
    /// note alongside it when one is given. Passing nil leaves any existing note
    /// untouched — a reviewer editing their public comment shouldn't silently
    /// erase what they said privately.
    func submit(_ review: Review, privateFeedback: String?) async throws
    /// The private note attached to a review. Readable only by its author and its
    /// subject; nil when there is none or the caller isn't one of them.
    func fetchPrivateFeedback(reviewID: String) async throws -> PrivateFeedback?

    func fetchReferences(subjectUserID: String) async throws -> [CharacterReference]
    func submitReference(_ reference: CharacterReference) async throws
    func deleteReference(id: String) async throws

    /// Friends the caller and `userID` have in common, computed by the
    /// `mutualFriends` callable — `friendEdges` are unreadable to third parties.
    func fetchMutualFriends(userID: String) async throws -> MutualFriends
}

struct FirestoreReviewsRepository: ReviewsRepository {
    private let db: Firestore
    private let functions: Functions
    init(db: Firestore = .firestore(), functions: Functions = .functions()) {
        self.db = db
        self.functions = functions
    }

    private func reviewDoc(_ reviewID: String) -> DocumentReference {
        db.collection(FirestorePaths.reviews).document(reviewID)
    }

    private func feedbackDoc(_ reviewID: String) -> DocumentReference {
        reviewDoc(reviewID)
            .collection(FirestorePaths.privateCollection)
            .document(FirestorePaths.feedbackDocID)
    }

    private func decodeReviews(_ documents: [QueryDocumentSnapshot]) -> [Review] {
        documents.compactMap { doc in
            do { return try doc.data(as: Review.self) }
            catch {
                Telemetry.decodeFailure(collection: FirestorePaths.reviews, documentID: doc.documentID, error: error)
                return nil
            }
        }
    }

    func fetchReviews(subjectUserID: String) async throws -> [Review] {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.reviews)
                .whereField("subjectUserID", isEqualTo: subjectUserID)
                .order(by: "createdAt", descending: true)
                .limit(to: reviewsFetchLimit)
                .getDocuments()
            return decodeReviews(snap.documents)
        }
    }

    func fetchReviewsWritten(byUserID authorUserID: String) async throws -> [Review] {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.reviews)
                .whereField("authorUserID", isEqualTo: authorUserID)
                .order(by: "createdAt", descending: true)
                .limit(to: reviewsFetchLimit)
                .getDocuments()
            return decodeReviews(snap.documents)
        }
    }

    func submit(_ review: Review, privateFeedback: String?) async throws {
        let review = review
        try await withRetry {
            let ref = reviewDoc(review.id)
            // A create must stamp createdAt with the server time; an edit must
            // leave it exactly as it was, and the rules only let it touch rating,
            // publicComment, and updatedAt. Writing the whole document on an edit
            // would rewrite createdAt to a fresh server timestamp and be rejected.
            if try await ref.getDocument().exists {
                // A cleared comment is removed rather than written as null: the
                // rules' isOptionalString() accepts both, but an absent key is
                // what the Swift encoder produces for nil everywhere else.
                let comment: Any = review.publicComment.map { $0 as Any } ?? FieldValue.delete()
                try await ref.updateData([
                    "rating": review.rating,
                    "publicComment": comment,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            } else {
                try ref.setData(from: review)
            }

            if let privateFeedback {
                try feedbackDoc(review.id).setData(from: PrivateFeedback(text: privateFeedback))
            }
        }
    }

    func fetchPrivateFeedback(reviewID: String) async throws -> PrivateFeedback? {
        try await withRetry {
            let snap = try await feedbackDoc(reviewID).getDocument()
            guard snap.exists else { return nil }
            return try snap.data(as: PrivateFeedback.self)
        }
    }

    func fetchReferences(subjectUserID: String) async throws -> [CharacterReference] {
        try await withRetry { [db] in
            let snap = try await db.collection(FirestorePaths.references)
                .whereField("subjectUserID", isEqualTo: subjectUserID)
                .order(by: "createdAt", descending: true)
                .limit(to: referencesFetchLimit)
                .getDocuments()
            return snap.documents.compactMap { doc in
                do { return try doc.data(as: CharacterReference.self) }
                catch {
                    Telemetry.decodeFailure(collection: FirestorePaths.references, documentID: doc.documentID, error: error)
                    return nil
                }
            }
        }
    }

    func submitReference(_ reference: CharacterReference) async throws {
        let reference = reference
        try await withRetry { [db] in
            let ref = db.collection(FirestorePaths.references).document(reference.id)
            // Same create/edit split as reviews: createdAt is immutable once set.
            if try await ref.getDocument().exists {
                try await ref.updateData([
                    "text": reference.text,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            } else {
                try ref.setData(from: reference)
            }
        }
    }

    func deleteReference(id: String) async throws {
        try await withRetry { [db] in
            try await db.collection(FirestorePaths.references).document(id).delete()
        }
    }

    func fetchMutualFriends(userID: String) async throws -> MutualFriends {
        let result = try await functions.httpsCallable("mutualFriends").call(["userID": userID])
        guard let payload = result.data as? [String: Any] else { return .empty }
        return MutualFriends(
            count: payload["count"] as? Int ?? 0,
            names: payload["names"] as? [String] ?? []
        )
    }
}

//
//  ReviewStore.swift
//  freebnb
//
//  Reviews, references, and mutual-friend counts, cached per user (features 1
//  and 2). Unlike the other stores this holds no snapshot listeners: a profile's
//  reviews change once per stay, so pages fetch on appear and the cache keeps a
//  second visit instant.
//

import FirebaseAuth
import Foundation
import Observation
import os

@MainActor
@Observable
final class ReviewStore {
    /// Reviews written about a user, keyed by that user's id.
    private(set) var reviewsBySubject: [String: [Review]] = [:]
    /// References written about a user, keyed by that user's id.
    private(set) var referencesBySubject: [String: [CharacterReference]] = [:]
    /// Mutual-friend counts against the signed-in user, keyed by the other user.
    private(set) var mutualFriendsByUser: [String: MutualFriends] = [:]
    /// Private notes attached to reviews, keyed by review id. Only ever populated
    /// for reviews the signed-in user authored or is the subject of — the rules
    /// refuse anyone else, so an absent entry here is also the honest answer.
    private(set) var privateFeedbackByReview: [String: PrivateFeedback] = [:]
    /// Stay-request ids the signed-in user has already reviewed. Drives the
    /// "needs your review" prompt, so it must be loaded before that prompt can
    /// honestly claim a stay is unreviewed.
    private(set) var reviewedStayIDs: Set<String> = []
    private(set) var hasLoadedOwnReviews = false

    @ObservationIgnored private let repository: ReviewsRepository
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    // In-flight fetches, so a page that appears twice doesn't fetch twice.
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let log = AppLog.logger("reviews")

    init(repository: ReviewsRepository = FirestoreReviewsRepository()) {
        self.repository = repository
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.reset(userID: user?.isAnonymous == false ? user?.uid : nil) }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    /// Everything here is scoped to the signed-in user (mutual friends literally
    /// are), so a sign-out must not leave the next account looking at it.
    private func reset(userID: String?) {
        reviewsBySubject = [:]
        referencesBySubject = [:]
        mutualFriendsByUser = [:]
        privateFeedbackByReview = [:]
        reviewedStayIDs = []
        hasLoadedOwnReviews = false
        inFlight = []
        guard userID != nil else { return }
        Task { await loadOwnReviews() }
    }

    // MARK: - Reads

    func reviews(about userID: String) -> [Review] { reviewsBySubject[userID] ?? [] }
    func references(about userID: String) -> [CharacterReference] { referencesBySubject[userID] ?? [] }
    func mutualFriends(with userID: String) -> MutualFriends? { mutualFriendsByUser[userID] }

    /// Whether the fetch has come back. "No reviews yet" and "still loading" look
    /// identical in an empty array, and only one of them is a claim about a person.
    func hasLoadedReviews(about userID: String) -> Bool { reviewsBySubject[userID] != nil }
    func hasLoadedReferences(about userID: String) -> Bool { referencesBySubject[userID] != nil }

    /// True once we know the answer and the answer is "not yet". Returns false
    /// while the signed-in user's own reviews are still loading, so the UI never
    /// nags someone to review a stay they already reviewed.
    func needsReview(stayRequestID: String) -> Bool {
        hasLoadedOwnReviews && !reviewedStayIDs.contains(stayRequestID)
    }

    func loadReviews(about userID: String) async {
        await once("reviews:\(userID)") {
            reviewsBySubject[userID] = try await repository.fetchReviews(subjectUserID: userID).sortedByDate()
        }
    }

    func loadReferences(about userID: String) async {
        await once("references:\(userID)") {
            referencesBySubject[userID] = try await repository.fetchReferences(subjectUserID: userID)
        }
    }

    func privateFeedback(reviewID: String) -> PrivateFeedback? { privateFeedbackByReview[reviewID] }

    /// Loads the private notes on the given reviews, one document each. Only the
    /// reviewer and the reviewed can read one, so a denial is expected rather than
    /// exceptional — `once` swallows it and the note simply doesn't render.
    func loadPrivateFeedback(for reviews: [Review]) async {
        for review in reviews {
            await once("feedback:\(review.id)") {
                if let feedback = try await repository.fetchPrivateFeedback(reviewID: review.id) {
                    privateFeedbackByReview[review.id] = feedback
                }
            }
        }
    }

    /// A count of shared friends, or nothing at all: this is a nice-to-have chip,
    /// and a failed callable should never surface an error to the user.
    func loadMutualFriends(with userID: String) async {
        guard let me = Auth.auth().currentUser?.uid, me != userID else { return }
        await once("mutual:\(userID)") {
            mutualFriendsByUser[userID] = try await repository.fetchMutualFriends(userID: userID)
        }
    }

    private func loadOwnReviews() async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        do {
            let mine = try await repository.fetchReviewsWritten(byUserID: me)
            reviewedStayIDs = Set(mine.map(\.stayRequestID))
            hasLoadedOwnReviews = true
        } catch {
            log.error("own reviews load error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Writes

    /// Publishes the caller's review of a finished stay. The private note, when
    /// given, goes to the reviewed person alone.
    func submitReview(_ review: Review, privateFeedback: String?) async throws {
        do {
            try await repository.submit(review, privateFeedback: privateFeedback)
        } catch {
            log.error("review submit error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        reviewedStayIDs.insert(review.stayRequestID)
        // The subject's cached list is now stale. Re-fetching beats splicing the
        // new review in locally, because the server owns the rating average — and
        // it has to be a re-fetch rather than a bare invalidation: the view that
        // shows this list already ran its `.task`, and won't run it again.
        invalidate(reviewsBySubject: review.subjectUserID)
    }

    private func invalidate(reviewsBySubject userID: String) {
        reviewsBySubject[userID] = nil
        inFlight.remove("reviews:\(userID)")
        Task { await loadReviews(about: userID) }
    }

    func submitReference(_ reference: CharacterReference) async throws {
        do {
            try await repository.submitReference(reference)
        } catch {
            log.error("reference submit error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        invalidateReferences(about: reference.subjectUserID)
    }

    func deleteReference(_ reference: CharacterReference) async throws {
        do {
            try await repository.deleteReference(id: reference.id)
        } catch {
            log.error("reference delete error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        invalidateReferences(about: reference.subjectUserID)
    }

    private func invalidateReferences(about userID: String) {
        referencesBySubject[userID] = nil
        inFlight.remove("references:\(userID)")
        Task { await loadReferences(about: userID) }
    }

    /// Runs `work` unless a fetch with the same key already ran or is running.
    /// SwiftUI calls `.task` again on every re-appearance, and each of these
    /// fetches is a billed read.
    ///
    /// A failure releases the key, so the next appearance retries. Keeping it
    /// would cache a network blip as "this person has no reviews" for the rest
    /// of the session, which is exactly the wrong thing to say about a stranger
    /// whose home someone is deciding to sleep in.
    private func once(_ key: String, _ work: () async throws -> Void) async {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        do {
            try await work()
        } catch {
            inFlight.remove(key)
            log.error("\(key, privacy: .public) load error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

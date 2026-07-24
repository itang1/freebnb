//
//  FirestorePaths.swift
//  freebnb
//
//  The single source of truth for Firestore collection, subcollection, and
//  well-known document names. Every repository, Cloud Function, security rule,
//  and seed/backfill script references the same collections; a typo in any one
//  of them silently reads or writes the wrong place. Keep this in sync with the
//  backend mirror in `functions/src/paths.ts`.
//

enum FirestorePaths {
    // Top-level collections
    static let homes = "homes"
    static let users = "users"
    static let stayRequests = "stayRequests"
    static let friendEdges = "friendEdges"
    static let conversations = "conversations"
    static let messages = "messages"
    static let reports = "reports"
    static let rateLimits = "rateLimits"
    /// Post-stay two-way reviews, one per (stay request, author).
    static let reviews = "reviews"
    /// Friend-written character references on a profile, one per (subject, author).
    static let references = "references"
    /// One document per (host, guest) pair, id `{hostID}_{guestID}`, counting the
    /// stay requests that guest has opened with that host inside the host's
    /// current frequency window. Advanced by the guest in the same commit as the
    /// request it governs, exactly as `rateLimits` is advanced alongside a
    /// message: security rules cannot run a query, so a counter the write rule
    /// can `getAfter()` is the only way to cap a rate. See docs/internal/CIRCLES.md.
    static let stayCounters = "stayCounters"

    // Subcollections
    /// Private data readable only by the owner: `users/{uid}/private`,
    /// `homes/{id}/private`.
    static let privateCollection = "private"
    /// Accepted-guest markers under a listing: `homes/{id}/accepted/{guestUID}`.
    static let accepted = "accepted"
    /// A host's Circles: `users/{hostID}/circles/{circleID}`. Host-only, and the
    /// Default circle always sits at the fixed id `Circle.defaultID`.
    static let circles = "circles"
    /// Which circle a host has filed each friend under, plus any per-friend
    /// override: `users/{hostID}/circleMembers/{friendUID}`. Host-only; keyed by
    /// the friend's uid so the rules resolve a policy in one get().
    static let circleMembers = "circleMembers"
    /// The resolved policy projected for one guest:
    /// `users/{hostID}/bookingPolicies/{guestUID}`. The only part of Circles a
    /// guest may read, and it deliberately carries no circle id and no circle
    /// name — only the rules that apply to them.
    static let bookingPolicies = "bookingPolicies"

    // Well-known document ids
    /// The listing's private street address: `homes/{id}/private/location`.
    static let locationDocID = "location"
    /// The listing's private house manual: `homes/{id}/private/manual`.
    static let manualDocID = "manual"
    /// The two halves of the listing's calendar, blocked and booked, kept apart
    /// from the merged copy the public document publishes:
    /// `homes/{id}/private/availability`. Managers only — unlike `location`, an
    /// accepted guest has no business here.
    static let availabilityDocID = "availability"
    /// The user's private profile: `users/{uid}/private/profile`.
    static let profileDocID = "profile"
    /// The reviewer's note to the reviewed, never public:
    /// `reviews/{reviewID}/private/feedback`.
    static let feedbackDocID = "feedback"
}

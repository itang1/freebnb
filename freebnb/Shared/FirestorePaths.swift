//
//  FirestorePaths.swift
//  freebnb
//
//  The single source of truth for Firestore collection and document names, shared
//  by repositories, rules and scripts; a typo silently hits the wrong place.
//  Mirrored in `functions/src/paths.ts`.
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
    /// One doc per (host, guest) pair, id `{hostID}_{guestID}`, counting the guest's
    /// requests in the host's current frequency window. Advanced in the same commit
    /// as the request, since rules can't query and can only `getAfter()` a counter.
    /// See docs/internal/CIRCLES.md.
    static let stayCounters = "stayCounters"

    // Subcollections
    /// Private data readable only by the owner: `users/{uid}/private`,
    /// `homes/{id}/private`.
    static let privateCollection = "private"
    /// Accepted-guest markers under a listing: `homes/{id}/accepted/{guestUID}`.
    static let accepted = "accepted"
    /// A host's Circles: `users/{hostID}/circles/{circleID}`. Host-only; Default is at `Circle.defaultID`.
    static let circles = "circles"
    /// Which circle a host filed each friend under, plus any override:
    /// `users/{hostID}/circleMembers/{friendUID}`. Host-only.
    static let circleMembers = "circleMembers"
    /// The resolved policy for one guest: `users/{hostID}/bookingPolicies/{guestUID}`.
    /// The only part of Circles a guest reads; carries no circle id or name.
    static let bookingPolicies = "bookingPolicies"
    /// A host's private notes on friends: `users/{hostID}/friendNotes/{noteID}`. That host alone reads them.
    static let friendNotes = "friendNotes"
    /// Which note prompts a host answered or waved off: `users/{hostID}/friendNotePrompts/{stayRequestID}`.
    static let friendNotePrompts = "friendNotePrompts"
    /// A guest's private notes on hosts and listings: `users/{guestID}/guestNotes/{noteID}`. That guest alone
    /// reads them.
    static let guestNotes = "guestNotes"
    /// Which note prompts a guest answered or waved off: `users/{guestID}/guestNotePrompts/{stayRequestID}`.
    static let guestNotePrompts = "guestNotePrompts"

    // Well-known document ids
    /// The listing's private street address: `homes/{id}/private/location`.
    static let locationDocID = "location"
    /// The listing's private house manual: `homes/{id}/private/manual`.
    static let manualDocID = "manual"
    /// The listing's blocked and booked halves, apart from the merged public copy:
    /// `homes/{id}/private/availability`. Managers only.
    static let availabilityDocID = "availability"
    /// The user's private profile: `users/{uid}/private/profile`.
    static let profileDocID = "profile"
    /// The reviewer's note to the reviewed, never public:
    /// `reviews/{reviewID}/private/feedback`.
    static let feedbackDocID = "feedback"
    /// The circle every host has and cannot delete, at a fixed id
    /// (`users/{hostID}/circles/default`). Fixed, not flagged, since rules can't
    /// query; see `FriendCircle.defaultID` and defaultCircleID() in the rules.
    static let defaultCircleDocID = "default"
}

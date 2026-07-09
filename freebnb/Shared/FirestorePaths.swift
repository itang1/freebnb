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

    // Subcollections
    /// Private data readable only by the owner: `users/{uid}/private`,
    /// `homes/{id}/private`.
    static let privateCollection = "private"
    /// Accepted-guest markers under a listing: `homes/{id}/accepted/{guestUID}`.
    static let accepted = "accepted"

    // Well-known document ids
    /// The listing's private street address: `homes/{id}/private/location`.
    static let locationDocID = "location"
    /// The user's private profile: `users/{uid}/private/profile`.
    static let profileDocID = "profile"
}

// The single source of truth for Firestore collection, subcollection, and
// well-known document names used by the Cloud Functions. This is the backend
// mirror of the iOS client's FirestorePaths.swift and the collections named in
// firestore.rules; keep the three in sync.

export const Collections = {
  homes: "homes",
  users: "users",
  stayRequests: "stayRequests",
  friendEdges: "friendEdges",
  conversations: "conversations",
  messages: "messages",
  reports: "reports",
  rateLimits: "rateLimits",
  // Post-stay two-way reviews, one per (stay request, author).
  reviews: "reviews",
  // Friend-written character references on a profile, one per (subject, author).
  references: "references",
  // Per-(host, guest) frequency counters behind a circle's booking policy, keyed
  // "{hostID}_{guestID}"; advanced with the stay request (docs/internal/CIRCLES.md).
  stayCounters: "stayCounters",
} as const;

export const Subcollections = {
  // Private data readable only by the owner: users/{uid}/private, homes/{id}/private.
  private: "private",
  // Accepted-guest markers under a listing: homes/{id}/accepted/{guestUID}.
  accepted: "accepted",
  // A host's Circles: users/{hostID}/circles/{circleID}. Host-only.
  circles: "circles",
  // Which circle each friend is in, plus any per-friend override:
  // users/{hostID}/circleMembers/{friendUID}. Host-only.
  circleMembers: "circleMembers",
  // The resolved policy for one guest: users/{hostID}/bookingPolicies/{guestUID}. The
  // only part of Circles a guest reads; no circle id or name.
  bookingPolicies: "bookingPolicies",
  // A host's private notes on friends: users/{hostID}/friendNotes/{noteID}. Host-only; no function touches them.
  friendNotes: "friendNotes",
  // Which post-stay note prompts a host dealt with: users/{hostID}/friendNotePrompts/{stayRequestID}. Only a timestamp.
  friendNotePrompts: "friendNotePrompts",
  // A guest's private notes on hosts and listings: users/{guestID}/guestNotes/{noteID}. Guest-only; no function touches them.
  guestNotes: "guestNotes",
  // Which post-trip note prompts a guest dealt with: users/{guestID}/guestNotePrompts/{stayRequestID}. Only a timestamp.
  guestNotePrompts: "guestNotePrompts",
} as const;

export const Docs = {
  // The listing's private street address: homes/{id}/private/location.
  location: "location",
  // The listing's blocked and booked halves: homes/{id}/private/availability. The public listing carries only their union.
  availability: "availability",
  // The user's private profile: users/{uid}/private/profile.
  profile: "profile",
  // The reviewer's note to the reviewed: reviews/{reviewID}/private/feedback.
  feedback: "feedback",
  // The circle every host has and cannot delete, at a fixed id so rules can reach it
  // (they can't query for a flag). Mirrors FriendCircle.defaultID.
  defaultCircle: "default",
} as const;

// users/{uid}/private/profile — the owner-only profile document.
export const privateProfilePath = (uid: string): string =>
  `${Collections.users}/${uid}/${Subcollections.private}/${Docs.profile}`;

// Storage object prefix for a user's listing photos: listings/{uid}/**.
export const listingPhotosPrefix = (uid: string): string => `listings/${uid}/`;

// Storage object prefix for one listing's photos: listings/{uid}/{homeID}/**.
// Mirrors the path storage.rules authorizes the host to write.
export const homePhotosPrefix = (uid: string, homeID: string): string =>
  `${listingPhotosPrefix(uid)}${homeID}/`;

// Firestore trigger path patterns.
export const homeDocPattern = `${Collections.homes}/{homeID}`;
export const messageDocPattern = `${Collections.messages}/{messageID}`;
export const friendEdgeDocPattern = `${Collections.friendEdges}/{edgeID}`;
export const stayRequestDocPattern = `${Collections.stayRequests}/{requestID}`;
// Reviews are keyed "{stayRequestID}_{authorUserID}" and references
// "{subjectUserID}_{authorUserID}", which makes "one per pair" enforceable in
// firestore.rules; functions only read these ids.
export const reviewDocPattern = `${Collections.reviews}/{reviewID}`;

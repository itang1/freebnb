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
  // "{hostID}_{guestID}". Advanced by the guest in the same commit as the stay
  // request; see docs/internal/CIRCLES.md.
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
  // The resolved policy projected for one guest:
  // users/{hostID}/bookingPolicies/{guestUID}. The only part of Circles a guest
  // may read, and it carries no circle id and no circle name.
  bookingPolicies: "bookingPolicies",
  // A host's private notes on their friends:
  // users/{hostID}/friendNotes/{noteID}. Host-only, with no projection for
  // anyone else, and no function reads or writes one.
  friendNotes: "friendNotes",
  // Which post-stay note prompts a host has already dealt with:
  // users/{hostID}/friendNotePrompts/{stayRequestID}. Host-only, and carries
  // only a timestamp.
  friendNotePrompts: "friendNotePrompts",
  // A guest's private notes on the hosts they stay with and the listings they
  // consider: users/{guestID}/guestNotes/{noteID}. The symmetric twin of
  // friendNotes, guest-only, with no projection for anyone else, and no function
  // reads or writes one.
  guestNotes: "guestNotes",
  // Which post-trip note prompts a guest has already dealt with:
  // users/{guestID}/guestNotePrompts/{stayRequestID}. Guest-only, and carries
  // only a timestamp.
  guestNotePrompts: "guestNotePrompts",
} as const;

export const Docs = {
  // The listing's private street address: homes/{id}/private/location.
  location: "location",
  // The listing's calendar with blocked and booked still apart:
  // homes/{id}/private/availability. The public listing document carries only
  // their union, so no guest can tell one from the other.
  availability: "availability",
  // The user's private profile: users/{uid}/private/profile.
  profile: "profile",
  // The reviewer's note to the reviewed: reviews/{reviewID}/private/feedback.
  feedback: "feedback",
  // The circle every host has and cannot delete, at a fixed id so a security
  // rule can always reach it — rules cannot ask which circle carries a flag.
  // Mirrors FriendCircle.defaultID in the Swift client.
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
// "{subjectUserID}_{authorUserID}". Those deterministic ids are what make
// "exactly one per pair" enforceable in firestore.rules rather than by a query
// the client could skip; the functions only ever read them, never mint them.
export const reviewDocPattern = `${Collections.reviews}/{reviewID}`;

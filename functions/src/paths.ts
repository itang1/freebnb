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
  // In-app feedback notes (feature 43). Moderator-readable only; users create.
  feedback: "feedback",
  // Post-stay two-way reviews, one per (stay request, author).
  reviews: "reviews",
  // Friend-written character references on a profile, one per (subject, author).
  references: "references",
} as const;

export const Subcollections = {
  // Private data readable only by the owner: users/{uid}/private, homes/{id}/private.
  private: "private",
  // Accepted-guest markers under a listing: homes/{id}/accepted/{guestUID}.
  accepted: "accepted",
} as const;

export const Docs = {
  // The listing's private street address: homes/{id}/private/location.
  location: "location",
  // The user's private profile: users/{uid}/private/profile.
  profile: "profile",
  // The reviewer's note to the reviewed: reviews/{reviewID}/private/feedback.
  feedback: "feedback",
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

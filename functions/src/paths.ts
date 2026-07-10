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
} as const;

// users/{uid}/private/profile — the owner-only profile document.
export const privateProfilePath = (uid: string): string =>
  `${Collections.users}/${uid}/${Subcollections.private}/${Docs.profile}`;

// Storage object prefix for a user's listing photos: listings/{uid}/**.
export const listingPhotosPrefix = (uid: string): string => `listings/${uid}/`;

// Firestore trigger path patterns.
export const messageDocPattern = `${Collections.messages}/{messageID}`;
export const friendEdgeDocPattern = `${Collections.friendEdges}/{edgeID}`;
export const stayRequestDocPattern = `${Collections.stayRequests}/{requestID}`;

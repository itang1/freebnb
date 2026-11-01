// Pure helpers behind the `listingPhotoURLs` callable, kept out of index.ts so they
// can be unit tested without initializing firebase-admin.
//
// Listing photos are private to the listing's audience. storage.rules denies every
// client read, so the only way to see a photo is a short-lived signed URL from the
// callable, which runs the same audience check as the `homes` read rule in
// firestore.rules.

import { homePhotosPrefix } from "./paths";

/** How long a signed photo URL stays valid. */
export const SIGNED_URL_TTL_MS = 60 * 60 * 1000;

/** The most photos a listing carries; mirrors `isOptionalList(data, 'photoURLs', 10)` in firestore.rules. */
export const MAX_LISTING_PHOTOS = 10;

/** The listing fields the audience check reads. */
export interface ListingAudience {
  hostUserID?: unknown;
  allowedViewerIDs?: unknown;
  coHostUserIDs?: unknown;
  deletedAt?: unknown;
}

/**
 * Whether `uid` may see this listing's photos. Mirrors the `homes` read rule in
 * firestore.rules (host, `allowedViewerIDs`, or `coHostUserIDs`); keep the two in
 * sync. A soft-deleted listing shows its photos to no one but the host.
 */
export function canViewListingPhotos(listing: ListingAudience, uid: string): boolean {
  if (typeof listing.hostUserID === "string" && listing.hostUserID === uid) return true;
  if (listing.deletedAt != null) return false;
  const inList = (value: unknown) => Array.isArray(value) && value.includes(uid);
  return inList(listing.allowedViewerIDs) || inList(listing.coHostUserIDs);
}

/**
 * The Storage object path a stored photo reference points at, or null if it isn't
 * one. A reference is either `gs://{bucket}/{path}` (what the app stores) or a
 * Firebase download URL `https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{encoded path}?…`
 * (or the emulator's `http://host:9199/v0/b/…`), which listings saved before
 * photos were locked down still carry. Mirrors `ListingPhotoPath.objectPath` in the app.
 */
export function objectPathFromPhotoRef(ref: string): string | null {
  let url: URL;
  try {
    url = new URL(ref);
  } catch {
    return null;
  }
  if (url.protocol === "gs:") {
    // gs://bucket/a/b/c.jpg -> host "bucket", pathname "/a/b/c.jpg"
    const path = decodeSafely(url.pathname.replace(/^\/+/, ""));
    return path ? path : null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const parts = url.pathname.split("/").filter((p) => p.length > 0);
  if (parts.length !== 5 || parts[0] !== "v0" || parts[1] !== "b" || parts[3] !== "o") return null;
  const path = decodeSafely(parts[4]);
  return path ? path : null;
}

/**
 * The object path for `ref` if it is one of this listing's own uploads, else null.
 * Co-hosts can rewrite `photoURLs`, so a reference is trusted only when it sits
 * under listings/{hostUserID}/{homeID}/; otherwise a listing could be pointed at
 * another listing's photos and the callable would sign them for this audience.
 * Traversal segments are refused for the same reason.
 */
export function ownedObjectPath(ref: unknown, hostUserID: string, homeID: string): string | null {
  if (typeof ref !== "string") return null;
  const path = objectPathFromPhotoRef(ref);
  if (!path) return null;
  const prefix = homePhotosPrefix(hostUserID, homeID);
  if (!path.startsWith(prefix) || path.length === prefix.length) return null;
  if (path.split("/").some((segment) => segment === "" || segment === "." || segment === "..")) return null;
  return path;
}

function decodeSafely(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

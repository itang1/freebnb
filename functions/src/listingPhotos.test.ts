// Unit tests for the listing-photo access helpers. Run with `npm test`.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { canViewListingPhotos, objectPathFromPhotoRef, ownedObjectPath } from "./listingPhotos";

const HOST = "host-1";
const HOME = "home-1";
const PATH = `listings/${HOST}/${HOME}/0b6f1c9e-2d1a-4c55-9d0a-7d2f3a1e9b10.jpg`;

test("host, allowed viewers and co-hosts can see photos", () => {
  const listing = { hostUserID: HOST, allowedViewerIDs: [HOST, "friend"], coHostUserIDs: ["cohost"] };
  assert.equal(canViewListingPhotos(listing, HOST), true);
  assert.equal(canViewListingPhotos(listing, "friend"), true);
  assert.equal(canViewListingPhotos(listing, "cohost"), true);
});

test("strangers can't see photos", () => {
  const listing = { hostUserID: HOST, allowedViewerIDs: [HOST, "friend"] };
  assert.equal(canViewListingPhotos(listing, "stranger"), false);
  assert.equal(canViewListingPhotos({ hostUserID: HOST }, "stranger"), false);
  // Malformed ACL fields deny rather than throw.
  assert.equal(canViewListingPhotos({ hostUserID: HOST, allowedViewerIDs: "stranger" }, "stranger"), false);
});

test("a soft-deleted listing shows photos to the host only", () => {
  const listing = { hostUserID: HOST, allowedViewerIDs: [HOST, "friend"], deletedAt: new Date() };
  assert.equal(canViewListingPhotos(listing, HOST), true);
  assert.equal(canViewListingPhotos(listing, "friend"), false);
});

test("parses gs:// references", () => {
  assert.equal(objectPathFromPhotoRef(`gs://freebnb.appspot.com/${PATH}`), PATH);
});

test("parses Firebase download URLs, production and emulator", () => {
  const encoded = encodeURIComponent(PATH);
  assert.equal(
    objectPathFromPhotoRef(`https://firebasestorage.googleapis.com/v0/b/freebnb.appspot.com/o/${encoded}?alt=media&token=abc`),
    PATH
  );
  assert.equal(objectPathFromPhotoRef(`http://127.0.0.1:9199/v0/b/freebnb.appspot.com/o/${encoded}?alt=media`), PATH);
});

test("rejects anything that isn't a Storage reference", () => {
  assert.equal(objectPathFromPhotoRef("not a url"), null);
  assert.equal(objectPathFromPhotoRef("https://example.com/photo.jpg"), null);
  assert.equal(objectPathFromPhotoRef("ftp://x/v0/b/bucket/o/path"), null);
  assert.equal(objectPathFromPhotoRef("gs://bucket"), null);
});

test("only signs this listing's own uploads", () => {
  assert.equal(ownedObjectPath(`gs://b/${PATH}`, HOST, HOME), PATH);
  // Another listing of the same host, or another host's listing: a co-host could write either into photoURLs.
  assert.equal(ownedObjectPath(`gs://b/listings/${HOST}/home-2/x.jpg`, HOST, HOME), null);
  assert.equal(ownedObjectPath(`gs://b/listings/other/${HOME}/x.jpg`, HOST, HOME), null);
  // A listing id that merely starts with this one.
  assert.equal(ownedObjectPath(`gs://b/listings/${HOST}/${HOME}x/x.jpg`, HOST, HOME), null);
  // The folder itself, traversal, and non-strings.
  assert.equal(ownedObjectPath(`gs://b/listings/${HOST}/${HOME}/`, HOST, HOME), null);
  const traversal = encodeURIComponent(`listings/${HOST}/${HOME}/../home-2/x.jpg`);
  assert.equal(ownedObjectPath(`https://h/v0/b/b/o/${traversal}`, HOST, HOME), null);
  assert.equal(ownedObjectPath(42, HOST, HOME), null);
});

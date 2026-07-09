#!/usr/bin/env node
//
// One-time backfill for progressive address disclosure (audit finding S2).
//
// Before: every signed-in user — including a throwaway anonymous account — could
// read `homes/{id}.address.street` and the exact geocoded coordinate.
//
// After: the listing document keeps city/state/zip and a coordinate rounded to
// two decimal places (~1 km). The street and the exact coordinate move to
// `homes/{id}/private/location`, which firestore.rules opens only to the host
// and to guests with an accepted stay.
//
// This script must run BEFORE the new firestore.rules are deployed: the rules
// reject any write to a listing whose `address` still carries a `street` key,
// which would otherwise brick edits and host renames on legacy documents.
//
// It also seeds `homes/{id}/accepted/{guestUserID}` for stays already accepted,
// so existing guests do not silently lose an address they were given.
//
// Idempotent: a listing whose street has already moved is skipped.
//
// Usage:
//   node scripts/backfill_address_privacy.js              # emulator
//   node scripts/backfill_address_privacy.js --dry-run    # print, write nothing
//   BACKFILL_CONFIRM_PROD=1 node scripts/backfill_address_privacy.js --prod

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");

if (useProd && process.env.BACKFILL_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to backfill the production project. Re-run with " +
    "BACKFILL_CONFIRM_PROD=1 node scripts/backfill_address_privacy.js --prod"
  );
  process.exit(1);
}

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
}

let admin;
try {
  admin = require("firebase-admin");
} catch {
  admin = require(path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"));
}

admin.initializeApp({ projectId: "freebnb-6814a" });
const db = admin.firestore();

const BATCH_LIMIT = 500;

// Must match Home.publicCoordinatePrecision / Home.approximate(_:) in Swift.
const COORDINATE_PRECISION = 2;

function approximate(value) {
  if (typeof value !== "number") return null;
  const scale = 10 ** COORDINATE_PRECISION;
  return Math.round(value * scale) / scale;
}

// Moves street + exact coordinates out of each listing document.
async function splitAddresses() {
  const homes = await db.collection("homes").get();
  const pending = [];

  for (const doc of homes.docs) {
    const home = doc.data();
    const street = home.address?.street;
    // Nothing to move. A listing written by a current client already looks like this.
    if (!street && home.latitude == null) continue;
    if (!street) continue;

    pending.push({
      ref: doc.ref,
      id: doc.id,
      street,
      exactLatitude: home.latitude ?? null,
      exactLongitude: home.longitude ?? null,
      address: { city: home.address.city, state: home.address.state, zip: home.address.zip ?? "" },
    });
  }

  console.log(`${homes.size} listings, ${pending.length} still carry a public street.`);
  if (dryRun) {
    for (const p of pending) console.log(`  ${p.id}: "${p.street}" -> private/location`);
    return;
  }

  // Two writes per listing (the doc and its private subdoc), so halve the chunk.
  const perChunk = Math.floor(BATCH_LIMIT / 2);
  for (let i = 0; i < pending.length; i += perChunk) {
    const batch = db.batch();
    for (const p of pending.slice(i, i + perChunk)) {
      const location = { street: p.street };
      if (p.exactLatitude != null) location.latitude = p.exactLatitude;
      if (p.exactLongitude != null) location.longitude = p.exactLongitude;
      batch.set(p.ref.collection("private").doc("location"), location);

      batch.update(p.ref, {
        address: p.address,
        latitude: approximate(p.exactLatitude),
        longitude: approximate(p.exactLongitude),
      });
    }
    await batch.commit();
    console.log(`  committed ${Math.min(i + perChunk, pending.length)}/${pending.length}`);
  }
}

// Re-grants the exact address to guests whose stays were accepted before the
// marker documents existed.
async function seedAcceptedMarkers() {
  const accepted = await db.collection("stayRequests").where("status", "==", "accepted").get();
  console.log(`${accepted.size} accepted stays to re-grant.`);
  if (dryRun) {
    for (const doc of accepted.docs) {
      const r = doc.data();
      console.log(`  homes/${r.listingID}/accepted/${r.guestUserID}`);
    }
    return;
  }

  for (let i = 0; i < accepted.docs.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const doc of accepted.docs.slice(i, i + BATCH_LIMIT)) {
      const request = doc.data();
      if (!request.listingID || !request.guestUserID) continue;
      batch.set(
        db.collection("homes").doc(request.listingID).collection("accepted").doc(request.guestUserID),
        {
          requestID: doc.id,
          guestUserID: request.guestUserID,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );
    }
    await batch.commit();
  }
}

async function main() {
  const target = useProd ? "PRODUCTION (freebnb-6814a)" : process.env.FIRESTORE_EMULATOR_HOST;
  console.log(`Splitting addresses against ${target}${dryRun ? " [dry run]" : ""}`);
  await splitAddresses();
  await seedAcceptedMarkers();
  console.log("Done.");
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);

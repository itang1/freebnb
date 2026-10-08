#!/usr/bin/env node
//
// One-off migration that takes a listing's calendar off the world-readable
// document.
//
// Listings used to publish `blockedDateRanges` and `bookedDateRanges` side by side
// on `homes/{id}`. Firestore grants reads per document, so every guest who could see
// a listing could subtract one from the other and learn which nights were occupied.
//
// After this script:
//
//   homes/{id}                       unavailableDateRanges: blocked ++ booked
//   homes/{id}/private/availability  blockedDateRanges, bookedDateRanges
//
// and the legacy fields are deleted from the public document. The private document
// is readable only by the listing's managers, not accepted guests.
//
// ORDER: deploy firestore.rules BEFORE running this; the new rules reject clients
// still writing the legacy keys. The iOS client reads either shape, so nothing is
// lost or over-shared in between.
//
// Idempotent: a listing with `unavailableDateRanges` and no legacy fields is skipped.
//
// Targets the Local Emulator Suite only; it refuses the real freebnb-6814a project
// unless you pass --prod AND set MIGRATE_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/migrate_split_availability.js              # emulator
//   node scripts/migrate_split_availability.js --dry-run    # print, write nothing
//   MIGRATE_CONFIRM_PROD=1 node scripts/migrate_split_availability.js --prod
//
// Requires firebase-admin (shared with functions/node_modules).

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");
if (useProd && process.env.MIGRATE_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to migrate the production project. Re-run with MIGRATE_CONFIRM_PROD=1 " +
    "node scripts/migrate_split_availability.js --prod if you really mean it."
  );
  process.exit(1);
}

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
}

// The functions copy first, deliberately: this script uses the namespaced v10 API,
// and the root's firebase-admin v14 has no `.firestore()` on its root export. The
// bare require is only a fallback.
let admin;
try {
  admin = require(path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"));
} catch {
  admin = require("firebase-admin");
}

admin.initializeApp({ projectId: "freebnb-6814a" });
const db = admin.firestore();

const PAGE_SIZE = 200;
// Mirrors isOptionalList(data, 'unavailableDateRanges', 200) in firestore.rules (the sum of the two former caps).
const UNION_CAP = 200;

/** A stored range is a map of two timestamps; anything else is not one. */
function isRange(value) {
  return (
    value &&
    typeof value === "object" &&
    value.start instanceof admin.firestore.Timestamp &&
    value.end instanceof admin.firestore.Timestamp
  );
}

/** Drops anything that isn't a well-formed range rather than publishing junk. */
function cleanRanges(value) {
  return Array.isArray(value) ? value.filter(isRange) : [];
}

async function main() {
  let scanned = 0;
  let migrated = 0;
  let skipped = 0;
  let cursor;

  for (;;) {
    let query = db.collection("homes").orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;

    const batch = db.batch();
    let writes = 0;
    for (const doc of snap.docs) {
      scanned++;
      const data = doc.data();
      const hasLegacy =
        data.blockedDateRanges !== undefined || data.bookedDateRanges !== undefined;
      const hasMerged = data.unavailableDateRanges !== undefined;

      // Already migrated; nothing to clean up.
      if (!hasLegacy && hasMerged) {
        skipped++;
        continue;
      }
      // No blocked or booked days means no availability at all; don't create an empty private document.
      if (!hasLegacy && !hasMerged) {
        skipped++;
        continue;
      }

      const blocked = cleanRanges(data.blockedDateRanges);
      const booked = cleanRanges(data.bookedDateRanges);
      const union = [...blocked, ...booked]
        .sort((a, b) => a.start.toMillis() - b.start.toMillis())
        .slice(0, UNION_CAP);

      console.log(
        `  ${doc.id}: ${blocked.length} blocked + ${booked.length} booked -> ` +
        `${union.length} unavailable, halves moved to private/availability`
      );
      migrated++;
      if (dryRun) continue;

      // Private document first: it's the source of truth and the public field is a
      // cache, so a crash between leaves the next edit to repair the cache.
      batch.set(
        doc.ref.collection("private").doc("availability"),
        { blockedDateRanges: blocked, bookedDateRanges: booked },
        { merge: true }
      );
      batch.update(doc.ref, {
        unavailableDateRanges: union,
        blockedDateRanges: admin.firestore.FieldValue.delete(),
        bookedDateRanges: admin.firestore.FieldValue.delete(),
      });
      writes += 2;
    }

    if (writes > 0) await batch.commit();
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_SIZE) break;
  }

  console.log(
    `\n${dryRun ? "[dry run] " : ""}scanned ${scanned} listings, ` +
    `migrated ${migrated}, already current ${skipped}.`
  );
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);

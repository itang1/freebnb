#!/usr/bin/env node
//
// One-off migration that takes a listing's calendar off the world-readable
// document.
//
// Listings used to publish `blockedDateRanges` and `bookedDateRanges` side by
// side on `homes/{id}`. Firestore grants reads per document and never per
// field, so every viewer of a listing — the host's accepted friends, which is
// to say every guest who can see it at all — received both arrays and could
// subtract one from the other to learn exactly which nights the home was
// occupied. The UI merged them on screen; the wire never did.
//
// After this script:
//
//   homes/{id}                       unavailableDateRanges: blocked ++ booked
//   homes/{id}/private/availability  blockedDateRanges, bookedDateRanges
//
// and the two legacy fields are deleted from the public document. The private
// document is readable only by the listing's managers — not by accepted guests,
// who get `location` and `manual` but have no business here.
//
// ORDER: deploy firestore.rules BEFORE running this. The new rules drop the two
// legacy keys from the listing's write allowlist, so a client that still tried
// to write them is rejected rather than quietly re-publishing what this removes.
// The iOS client reads either shape (it falls back to the union of the legacy
// pair when `unavailableDateRanges` is absent), so between deploy and migration
// nothing is lost and nothing is over-shared that wasn't already.
//
// IDEMPOTENT: a listing that already carries `unavailableDateRanges` and no
// legacy fields is skipped. Safe to re-run after a partial failure.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite only. It refuses to touch
// the real freebnb-6814a project unless you pass --prod AND set
// MIGRATE_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/migrate_split_availability.js              # emulator
//   node scripts/migrate_split_availability.js --dry-run    # print, write nothing
//   MIGRATE_CONFIRM_PROD=1 node scripts/migrate_split_availability.js --prod
//
// Requires firebase-admin (shared with functions/node_modules, like the other
// scripts here).

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

// The functions copy first, deliberately. This script is written against the
// namespaced v10 API (`admin.firestore()`, `admin.firestore.Timestamp`), and the
// repo root also carries a firebase-admin v14, whose modular API exposes no
// `.firestore()` on the root export. Requiring bare picks up v14 and dies at the
// first call, so the pinned copy wins and the bare require is only a fallback for
// a checkout without functions/node_modules installed.
let admin;
try {
  admin = require(path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"));
} catch {
  admin = require("firebase-admin");
}

admin.initializeApp({ projectId: "freebnb-6814a" });
const db = admin.firestore();

const PAGE_SIZE = 200;
// Mirrors isOptionalList(data, 'unavailableDateRanges', 200) in firestore.rules,
// itself the sum of the two former per-field caps.
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

      // Already migrated, and nothing left behind to clean up.
      if (!hasLegacy && hasMerged) {
        skipped++;
        continue;
      }
      // A listing that never blocked or booked a day has no availability at all.
      // Nothing to move, and writing an empty private document would only create
      // a document where none is needed.
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

      // The private document first: it becomes the source of truth, and the
      // public field is only a cache of the union. A crash between the two
      // leaves the truth written and the cache stale, which the next
      // availability edit or stay change repairs. The other order would leave
      // the halves nowhere.
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

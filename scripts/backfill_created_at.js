#!/usr/bin/env node
//
// One-time backfill of `createdAt` on listings (audit finding L3).
//
// The feed now orders `homes` by `createdAt DESC`. Firestore's order-by
// excludes documents that lack the ordered field, so any listing created
// before this field existed drops out of the feed entirely until it has one.
// Run this before deploying the ordered-feed rules and indexes.
//
// Legacy listings have no real creation time to recover, so each missing one is
// stamped with the server time at backfill. They therefore share (roughly) a
// timestamp and fall back to the document-id tiebreak the feed query applies;
// listings created afterward sort ahead of them, which is the intent.
//
// Idempotent: a listing that already has `createdAt` is skipped, so re-running
// never rewrites a real creation time.
//
// Usage:
//   node scripts/backfill_created_at.js              # emulator
//   node scripts/backfill_created_at.js --dry-run    # print, write nothing
//   BACKFILL_CONFIRM_PROD=1 node scripts/backfill_created_at.js --prod
//
// Requires firebase-admin (see scripts/seed_test_data.js for the same setup).

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");

if (useProd && process.env.BACKFILL_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to backfill the production project. Re-run with " +
    "BACKFILL_CONFIRM_PROD=1 node scripts/backfill_created_at.js --prod"
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

async function main() {
  const target = useProd ? "PRODUCTION (freebnb-6814a)" : process.env.FIRESTORE_EMULATOR_HOST;
  console.log(`Backfilling homes.createdAt against ${target}${dryRun ? " [dry run]" : ""}`);

  const homes = await db.collection("homes").get();

  const pending = [];
  for (const doc of homes.docs) {
    // Only stamp listings that have no createdAt yet.
    if (doc.data().createdAt !== undefined) continue;
    pending.push({ ref: doc.ref, id: doc.id });
  }

  console.log(`${homes.size} listings, ${pending.length} missing createdAt.`);
  if (dryRun) {
    for (const p of pending) console.log(`  ${p.id}`);
    return;
  }

  for (let i = 0; i < pending.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const p of pending.slice(i, i + BATCH_LIMIT)) {
      batch.update(p.ref, { createdAt: admin.firestore.FieldValue.serverTimestamp() });
    }
    await batch.commit();
    console.log(`  committed ${Math.min(i + BATCH_LIMIT, pending.length)}/${pending.length}`);
  }
  console.log("Done.");
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);

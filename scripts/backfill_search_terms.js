#!/usr/bin/env node
//
// Backfills `searchTerms` onto every public user doc (R1).
//
// Friend search queries that array. A document written before this field
// existed has no terms, so it matches nothing and the user is invisible to
// search until this runs. New and renamed profiles maintain the field
// themselves (UserProfileRepository), so this is a one-shot for existing docs.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite. Touching the real
// freebnb-6814a project needs --prod AND BACKFILL_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/backfill_search_terms.js [--dry-run]
//   BACKFILL_CONFIRM_PROD=1 node scripts/backfill_search_terms.js --prod
//
// Idempotent: a document whose terms already match is skipped, so re-running
// costs reads and no writes. Safe to run before the rules deploy — the Admin
// SDK bypasses rules — but pointless until the client that queries the field
// ships.

"use strict";

const path = require("path");
const { createRequire } = require("module");
const { searchTerms } = require("./search_terms");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");

if (useProd && process.env.BACKFILL_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to touch the production project. Re-run with " +
    "BACKFILL_CONFIRM_PROD=1 node scripts/backfill_search_terms.js --prod " +
    "if you really mean it."
  );
  process.exit(1);
}

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
}

// Same resolution dance as seed_test_data.js: prefer a repo-root
// firebase-admin, fall back to the copy functions/ always depends on.
let adminRequire = require;
try {
  require.resolve("firebase-admin/app");
} catch {
  adminRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));
}
const { initializeApp } = adminRequire("firebase-admin/app");
const { getFirestore } = adminRequire("firebase-admin/firestore");

initializeApp({ projectId: "freebnb-6814a" });
const db = getFirestore();

/** True when the stored array already carries exactly the terms we'd write. */
function isCurrent(existing, wanted) {
  if (!Array.isArray(existing) || existing.length !== wanted.length) return false;
  const have = new Set(existing);
  return wanted.every((term) => have.has(term));
}

async function main() {
  console.log(
    `Backfilling searchTerms against ${useProd ? "PRODUCTION (freebnb-6814a)" : "the local emulator"}` +
    `${dryRun ? " [dry run]" : ""}...`
  );

  const snapshot = await db.collection("users").get();
  let written = 0;
  let skipped = 0;
  let nameless = 0;

  // Batched: a directory of any size would otherwise be one write per round
  // trip. 400 keeps clear of the 500-op limit.
  let batch = db.batch();
  let pending = 0;

  for (const doc of snapshot.docs) {
    const displayName = doc.data().displayName;
    if (typeof displayName !== "string" || displayName.trim() === "") {
      // A doc with no name can't be indexed, and the rules require the name to
      // be present among the terms. Leave it alone and say so.
      nameless++;
      continue;
    }

    const wanted = searchTerms(displayName);
    if (isCurrent(doc.data().searchTerms, wanted)) {
      skipped++;
      continue;
    }

    if (!dryRun) {
      batch.update(doc.ref, { searchTerms: wanted });
      pending++;
      if (pending >= 400) {
        await batch.commit();
        batch = db.batch();
        pending = 0;
      }
    }
    written++;
  }

  if (!dryRun && pending > 0) await batch.commit();

  console.log(
    `Done. ${written} ${dryRun ? "would be updated" : "updated"}, ` +
    `${skipped} already current, ${nameless} skipped for having no displayName.`
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

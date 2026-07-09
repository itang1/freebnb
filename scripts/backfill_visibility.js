#!/usr/bin/env node
//
// One-time backfill for server-enforced listing visibility (audit finding S1).
//
// Two fields are now load-bearing for the `homes` read rule:
//
//   visibility        'everyone' | 'friendsOnly'
//   allowedViewerIDs  [hostUserID, ...accepted friends of the host]
//
// The feed queries `visibility == 'everyone'` and `allowedViewerIDs contains me`,
// so a listing missing either field drops out of the feed entirely. Run this
// before deploying the new firestore.rules, and again if a bulk import ever
// writes listings outside the app.
//
// Idempotent: re-running recomputes the same values.
//
// Usage:
//   node scripts/backfill_visibility.js              # emulator
//   node scripts/backfill_visibility.js --dry-run    # print, write nothing
//   BACKFILL_CONFIRM_PROD=1 node scripts/backfill_visibility.js --prod
//
// Requires firebase-admin (see scripts/seed_test_data.js for the same setup).

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");

if (useProd && process.env.BACKFILL_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to backfill the production project. Re-run with " +
    "BACKFILL_CONFIRM_PROD=1 node scripts/backfill_visibility.js --prod"
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

// uid -> Set of uids they are accepted friends with.
async function loadFriendGraph() {
  const snap = await db.collection("friendEdges").where("status", "==", "accepted").get();
  const graph = new Map();
  const link = (a, b) => {
    if (!graph.has(a)) graph.set(a, new Set());
    graph.get(a).add(b);
  };
  for (const doc of snap.docs) {
    const { userA, userB } = doc.data();
    if (!userA || !userB) continue;
    link(userA, userB);
    link(userB, userA);
  }
  return graph;
}

function sameMembers(a, b) {
  if (!Array.isArray(a) || a.length !== b.length) return false;
  const set = new Set(a);
  return b.every((id) => set.has(id));
}

async function main() {
  const target = useProd ? "PRODUCTION (freebnb-6814a)" : process.env.FIRESTORE_EMULATOR_HOST;
  console.log(`Backfilling visibility against ${target}${dryRun ? " [dry run]" : ""}`);

  const friends = await loadFriendGraph();
  const homes = await db.collection("homes").get();

  const pending = [];
  for (const doc of homes.docs) {
    const home = doc.data();
    const hostUserID = home.hostUserID;
    if (!hostUserID) {
      console.warn(`  skip ${doc.id}: no hostUserID`);
      continue;
    }
    // The host always sees their own listing, friends-only or not.
    const viewers = [hostUserID, ...(friends.get(hostUserID) ?? [])];
    const visibility = home.visibility ?? "everyone";

    if (home.visibility === visibility && sameMembers(home.allowedViewerIDs, viewers)) continue;
    pending.push({ ref: doc.ref, id: doc.id, visibility, viewers });
  }

  console.log(`${homes.size} listings, ${pending.length} need updating.`);
  if (dryRun) {
    for (const p of pending) {
      console.log(`  ${p.id}: visibility=${p.visibility} viewers=${p.viewers.length}`);
    }
    return;
  }

  for (let i = 0; i < pending.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const p of pending.slice(i, i + BATCH_LIMIT)) {
      batch.update(p.ref, { visibility: p.visibility, allowedViewerIDs: p.viewers });
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

#!/usr/bin/env node
//
// One-off migration to the friends-only listing model.
//
// Listings used to carry a `visibility` tier ('everyone' / 'friendsOnly' /
// 'friendsOfFriends') that widened who could read them. The tiers are gone:
// every listing is now readable only by its host, co-hosts, and the host's
// accepted friends, enforced through `allowedViewerIDs`. This script brings
// existing documents in line:
//
//   - deletes the legacy `visibility` field, and
//   - rewrites `allowedViewerIDs` to host + accepted friends (capped at 1000,
//     matching the rules), exactly what rebuildListingACLs now maintains.
//
// Deploy the new firestore.rules and functions BEFORE running this. The rules
// already ignore `visibility`, so between deploy and migration old documents
// are at worst too private, never too public.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite only. It refuses to touch
// the real freebnb-6814a project unless you pass --prod AND set
// MIGRATE_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/migrate_friends_only.js                 # emulator
//   node scripts/migrate_friends_only.js --dry-run       # print, write nothing
//   MIGRATE_CONFIRM_PROD=1 node scripts/migrate_friends_only.js --prod
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
    "node scripts/migrate_friends_only.js --prod if you really mean it."
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

// Mirrors the rules' 1000-entry cap on allowedViewerIDs.
const ACL_CAP = 1000;
const PAGE_SIZE = 200;

async function acceptedFriendsOf(userID) {
  const [aSnap, bSnap] = await Promise.all([
    db.collection("friendEdges").where("userA", "==", userID).where("status", "==", "accepted").get(),
    db.collection("friendEdges").where("userB", "==", userID).where("status", "==", "accepted").get(),
  ]);
  return [...aSnap.docs.map((d) => d.data().userB), ...bSnap.docs.map((d) => d.data().userA)];
}

function sameMembers(a, b) {
  if (a.length !== b.length) return false;
  const set = new Set(a);
  return b.every((id) => set.has(id));
}

async function main() {
  // Friend lists are fetched once per host, not once per listing.
  const friendsByHost = new Map();
  const desiredACLFor = async (hostID) => {
    if (!friendsByHost.has(hostID)) {
      friendsByHost.set(hostID, [...new Set([hostID, ...(await acceptedFriendsOf(hostID))])].slice(0, ACL_CAP));
    }
    return friendsByHost.get(hostID);
  };

  let scanned = 0;
  let migrated = 0;
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
      const hostID = data.hostUserID;
      if (typeof hostID !== "string" || hostID.length === 0) {
        console.warn(`  skipping ${doc.id}: no hostUserID`);
        continue;
      }
      const desired = await desiredACLFor(hostID);
      const aclCurrent = sameMembers(data.allowedViewerIDs ?? [], desired);
      const hasLegacyField = data.visibility !== undefined;
      if (aclCurrent && !hasLegacyField) continue;

      const was = hasLegacyField ? data.visibility : "(unset)";
      console.log(`  ${doc.id}: visibility ${was} -> friends-only, ACL ${(data.allowedViewerIDs ?? []).length} -> ${desired.length} viewers`);
      migrated++;
      if (dryRun) continue;
      batch.update(doc.ref, {
        visibility: admin.firestore.FieldValue.delete(),
        allowedViewerIDs: desired,
      });
      writes++;
    }
    if (writes > 0) await batch.commit();

    if (snap.size < PAGE_SIZE) break;
    cursor = snap.docs[snap.docs.length - 1].id;
  }

  console.log(
    `${dryRun ? "[dry run] " : ""}Scanned ${scanned} listings; ` +
    `${migrated}${dryRun ? " would be" : ""} migrated to friends-only.`
  );
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);

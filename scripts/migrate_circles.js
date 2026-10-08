#!/usr/bin/env node
//
// One-off migration to Circles — friend-grouped booking rules.
//
// Circles let a host sort their friends into named groups and hang a booking
// policy off each one. Before the feature means anything, every existing account needs:
//
//   - every host has the starter circles, including Default at the fixed id
//     `default`, where every policy resolution in firestore.rules terminates; and
//   - every accepted friend has a `circleMembers` document naming a circle.
//
// Default is a real policy-bearing circle, not an implicit fallback. The rules do
// fall back to Default for an unfiled friend so a just-accepted friendship is
// enforceable, but relying on that would stop the host's screen telling a friend
// deliberately left in Default from one never filed.
//
// Everyone is filed under Default with the permissive starter policy, so this
// changes what nobody may do; hosts restrict people by hand afterwards. It also
// writes the guest-readable projection at users/{hostID}/bookingPolicies/{friendID}
// that the request sheet reads (without it the sheet offers everything, which is
// safe since the rules are the boundary, but a guest may meet a rejection).
//
// Nothing here touches a stay; Circles apply prospectively.
//
// Deploy the new firestore.rules BEFORE running this. Until migration a host has no
// circles, which the rules read as "nothing restricted".
//
// Targets the Local Emulator Suite only; it refuses the real freebnb-6814a project
// unless you pass --prod AND set MIGRATE_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/migrate_circles.js                 # emulator
//   node scripts/migrate_circles.js --dry-run       # print, write nothing
//   MIGRATE_CONFIRM_PROD=1 node scripts/migrate_circles.js --prod
//
// Idempotent: re-running files only what's missing and never overwrites a renamed
// or reconfigured circle, nor a friend a host has moved.

"use strict";

const path = require("path");
const { createRequire } = require("module");

const useProd = process.argv.includes("--prod");
const dryRun = process.argv.includes("--dry-run");
if (useProd && process.env.MIGRATE_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to migrate the production project. Re-run with MIGRATE_CONFIRM_PROD=1 " +
    "node scripts/migrate_circles.js --prod if you really mean it."
  );
  process.exit(1);
}

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
}

// The modular firebase-admin API, resolved as in seed_test_data.js (v13 removed the
// legacy namespace); prefers the root copy and falls back to functions/'s.
let adminRequire = require;
try {
  require.resolve("firebase-admin/app");
} catch {
  adminRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));
}
const { initializeApp } = adminRequire("firebase-admin/app");
const { getFirestore, FieldValue, FieldPath } = adminRequire("firebase-admin/firestore");

initializeApp({ projectId: "freebnb-6814a" });
const db = getFirestore();

const PAGE_SIZE = 200;

// The fixed id of the undeletable circle; mirrors FriendCircle.defaultID and
// defaultCircleID() in firestore.rules (rules-tests/mirrors.test.mjs asserts all three agree).
const DEFAULT_CIRCLE_ID = "default";

// Mirrors ArrivalWindow in the Swift client.
const ARRIVAL_OPTIONS = ["flexible", "morning", "afternoon", "evening", "lateNight"];

// What every circle starts as, Default included. All three ship permissive, since a
// seeded restriction is a decline the host never made.
const PERMISSIVE_POLICY = {
  allowedArrivalOptions: ARRIVAL_OPTIONS,
  minNoticeHours: 0,
  maxStaysPerPeriod: null,
};

// Mirrors FriendCircle.seeded(). The two beyond Default are ordinary circles, there so a host has somewhere to drag people.
const SEEDED_CIRCLES = [
  { id: DEFAULT_CIRCLE_ID, name: "Everyone else", isDefault: true, sortOrder: 0 },
  { id: "closeFriend", name: "Close friend", isDefault: false, sortOrder: 1 },
  { id: "acquaintance", name: "Acquaintance", isDefault: false, sortOrder: 2 },
];

/** Everyone `userID` has an accepted friend edge with, in both directions. */
async function acceptedFriendsOf(userID) {
  const [aSnap, bSnap] = await Promise.all([
    db.collection("friendEdges").where("userA", "==", userID).where("status", "==", "accepted").get(),
    db.collection("friendEdges").where("userB", "==", userID).where("status", "==", "accepted").get(),
  ]);
  return [
    ...aSnap.docs.map((d) => d.data().userB),
    ...bSnap.docs.map((d) => d.data().userA),
  ].filter((id) => typeof id === "string" && id.length > 0 && id !== userID);
}

/**
 * Seeds the starter circles for one host, skipping any that already exist.
 * Returns the Default circle's policy, which is what the friends below get
 * filed under — read back rather than assumed, so a host who has already
 * tightened Default has that policy projected and not the permissive one.
 */
async function ensureCircles(hostID, counters) {
  const circles = db.collection("users").doc(hostID).collection("circles");
  const existing = await circles.get();
  const present = new Set(existing.docs.map((d) => d.id));

  const missing = SEEDED_CIRCLES.filter((c) => !present.has(c.id));
  if (missing.length > 0) {
    console.log(`  ${hostID}: seeding ${missing.map((c) => c.id).join(", ")}`);
    counters.circlesSeeded += missing.length;
    if (!dryRun) {
      const batch = db.batch();
      const now = FieldValue.serverTimestamp();
      for (const circle of missing) {
        batch.set(circles.doc(circle.id), {
          name: circle.name,
          isDefault: circle.isDefault,
          sortOrder: circle.sortOrder,
          policy: PERMISSIVE_POLICY,
          createdAt: now,
          updatedAt: now,
        });
      }
      await batch.commit();
    }
  }

  const already = existing.docs.find((d) => d.id === DEFAULT_CIRCLE_ID);
  return already?.data()?.policy ?? PERMISSIVE_POLICY;
}

/**
 * Files every unfiled friend of `hostID` under Default, and publishes the
 * policy each of them resolves to.
 *
 * A friend who already has a membership is left exactly as they are — the host
 * may have moved them deliberately, and this script has no business undoing
 * that. Their projection is still refreshed, because a projection that has
 * drifted from the policy is the one failure mode that reaches a guest.
 */
async function fileFriends(hostID, defaultPolicy, counters) {
  const friendIDs = [...new Set(await acceptedFriendsOf(hostID))];
  if (friendIDs.length === 0) return;

  const members = db.collection("users").doc(hostID).collection("circleMembers");
  const circles = db.collection("users").doc(hostID).collection("circles");
  const policies = db.collection("users").doc(hostID).collection("bookingPolicies");

  const [memberSnap, circleSnap] = await Promise.all([members.get(), circles.get()]);
  const membershipByFriend = new Map(memberSnap.docs.map((d) => [d.id, d.data()]));
  const policyByCircle = new Map(circleSnap.docs.map((d) => [d.id, d.data()?.policy]));

  let batch = db.batch();
  let writes = 0;

  for (const friendID of friendIDs) {
    const membership = membershipByFriend.get(friendID);

    if (!membership) {
      console.log(`  ${hostID}: filing ${friendID} under ${DEFAULT_CIRCLE_ID}`);
      counters.friendsFiled += 1;
      if (!dryRun) {
        batch.set(members.doc(friendID), {
          circleID: DEFAULT_CIRCLE_ID,
          updatedAt: FieldValue.serverTimestamp(),
        });
        writes += 1;
      }
    }

    // The chain firestore.rules and CirclePolicyResolver walk: override, named circle, Default.
    const resolved =
      membership?.overridePolicy ??
      policyByCircle.get(membership?.circleID) ??
      defaultPolicy;

    counters.policiesPublished += 1;
    if (!dryRun) {
      batch.set(policies.doc(friendID), resolved);
      writes += 1;
    }

    // Stay well under the 500-op batch cap.
    if (writes >= 400) {
      await batch.commit();
      batch = db.batch();
      writes = 0;
    }
  }

  if (writes > 0) await batch.commit();
}

async function main() {
  const counters = { users: 0, circlesSeeded: 0, friendsFiled: 0, policiesPublished: 0 };
  let cursor = null;

  // Paged by document id so a large user collection doesn't come back at once.
  for (;;) {
    let query = db.collection("users").orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      counters.users += 1;
      const defaultPolicy = await ensureCircles(doc.id, counters);
      await fileFriends(doc.id, defaultPolicy, counters);
    }

    if (snap.size < PAGE_SIZE) break;
    cursor = snap.docs[snap.docs.length - 1].id;
  }

  const prefix = dryRun ? "[dry run] " : "";
  console.log(
    `${prefix}Scanned ${counters.users} users; ` +
    `${counters.circlesSeeded}${dryRun ? " would be" : ""} circles seeded, ` +
    `${counters.friendsFiled} friends filed under ${DEFAULT_CIRCLE_ID}, ` +
    `${counters.policiesPublished} policies published.`
  );
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);

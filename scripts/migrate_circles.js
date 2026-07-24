#!/usr/bin/env node
//
// One-off migration to Circles — friend-grouped booking rules.
//
// Circles let a host sort their friends into named groups and hang a booking
// policy off each one. Two things have to be true of every existing account
// before the feature means anything:
//
//   - every host has the starter circles, including the Default one at the
//     fixed id `default`, because that id is where every policy resolution in
//     firestore.rules terminates; and
//   - every accepted friend has a `circleMembers` document naming a circle.
//
// The second is the point of running this at all. Default is a real,
// policy-bearing circle now, not an implicit fallback — a friend with no
// membership document is a gap the rules paper over, not a representation of
// "in the Default circle". The rules do fall back to Default for such a friend,
// deliberately, so that a friendship accepted seconds ago is not unenforceable;
// but leaning on that as the steady state would mean the host's own screen
// could not tell a friend they had deliberately left in Default from one nobody
// had ever filed.
//
// Everyone is filed under Default with the permissive starter policy, so this
// migration changes what *nobody* may do: it is the identity of the feature,
// written down. Hosts restrict people afterwards, by hand.
//
// It also writes the guest-readable projection at
// users/{hostID}/bookingPolicies/{friendID}, which is what a guest's request
// sheet reads to know which arrival options to offer. Without it the sheet
// falls back to offering everything — safe, because the rules are the real
// boundary, but it would mean a guest occasionally meets a rejection instead of
// simply not being offered the option.
//
// Nothing here touches a stay. Circles apply prospectively: an accepted stay
// stays accepted, whatever policy lands afterwards.
//
// Deploy the new firestore.rules BEFORE running this. Between deploy and
// migration a host simply has no circles, which the rules read as "nothing
// configured, nothing restricted" — the behaviour they had before the feature.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite only. It refuses to touch
// the real freebnb-6814a project unless you pass --prod AND set
// MIGRATE_CONFIRM_PROD=1.
//
// Usage:
//   node scripts/migrate_circles.js                 # emulator
//   node scripts/migrate_circles.js --dry-run       # print, write nothing
//   MIGRATE_CONFIRM_PROD=1 node scripts/migrate_circles.js --prod
//
// Idempotent: re-running files only what is missing and never overwrites a
// circle a host has since renamed or reconfigured, nor a friend they have moved.

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

// The modular firebase-admin API, resolved the same way seed_test_data.js does:
// the legacy namespace (admin.firestore.FieldValue) was removed in v13, and the
// repo root now carries v14. Prefer the root copy; fall back to the one
// functions/ always depends on.
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

// The fixed id of the circle that cannot be deleted. Mirrors
// FriendCircle.defaultID in the Swift client and defaultCircleID() in
// firestore.rules; rules-tests/mirrors.test.mjs asserts the three agree.
const DEFAULT_CIRCLE_ID = "default";

// Mirrors ArrivalWindow in the Swift client.
const ARRIVAL_OPTIONS = ["flexible", "morning", "afternoon", "evening", "lateNight"];

// What every circle starts as, Default included. A seeded restriction is a
// decline the host never made, so all three ship permissive and the host
// tightens the ones they want.
const PERMISSIVE_POLICY = {
  allowedArrivalOptions: ARRIVAL_OPTIONS,
  minNoticeHours: 0,
  maxStaysPerPeriod: null,
};

// Mirrors FriendCircle.seeded(). The two beyond Default are ordinary circles:
// renameable, deletable, and there only so a host has somewhere obvious to drag
// people to.
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

    // The same chain firestore.rules walks and CirclePolicyResolver walks:
    // override, then the named circle, then Default.
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

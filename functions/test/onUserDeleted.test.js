// onUserDeleted is the server-side cascade behind account deletion. These seed
// one departing user's footprint next to a bystander's, run the trigger, and
// check that exactly the departing user's data went and the bystander's stayed.
const { test, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { setup } = require("./harness");

const h = setup("freebnb-fn-user-deleted");
const onUserDeleted = h.fft.wrap(h.functions.onUserDeleted);

const GONE = "gone";
const FRIEND = "friend";

const exists = async (path) => (await h.db.doc(path).get()).exists;
const ids = async (path) => (await h.db.collection(path).get()).docs.map((d) => d.id).sort();

async function seed() {
  const w = (path, data) => h.db.doc(path).set(data);
  await Promise.all([
    w(`users/${GONE}`, { displayName: "Gone" }),
    w(`users/${GONE}/private/profile`, { fcmToken: "t" }),
    // Stats deliberately stale, so the recompute is visible.
    w(`users/${FRIEND}`, { displayName: "Friend", trustStats: { staysHosted: 9, staysTaken: 9, reviewCount: 9 } }),

    // The departing user's listing, its address, and a guest's access to it.
    w("homes/goneHome", { hostUserID: GONE, title: "Loft" }),
    w("homes/goneHome/private/location", { street: "1 Main St" }),
    w("homes/goneHome/accepted/g1", { guestUserID: "g1", requestID: "s2" }),
    // The friend's listing, where the departing user held an address as a guest.
    w("homes/friendHome", { hostUserID: FRIEND, title: "Cabin" }),
    w("homes/friendHome/private/location", { street: "2 Oak Ave" }),
    w(`homes/friendHome/accepted/${GONE}`, { guestUserID: GONE, requestID: "s1" }),
    w("homes/friendHome/accepted/g2", { guestUserID: "g2", requestID: "s3" }),

    // Reviews both ways, with the private feedback subdocument, plus one that isn't theirs.
    w("reviews/s1_gone", { authorUserID: GONE, subjectUserID: FRIEND, rating: 5 }),
    w("reviews/s1_gone/private/feedback", { note: "lovely" }),
    w("reviews/s1_friend", { authorUserID: FRIEND, subjectUserID: GONE, rating: 4 }),
    w("reviews/s3_g2", { authorUserID: "g2", subjectUserID: FRIEND, rating: 3 }),
    w("references/friend_gone", { authorUserID: GONE, subjectUserID: FRIEND }),
    w("references/gone_friend", { authorUserID: FRIEND, subjectUserID: GONE }),
    w("references/friend_g2", { authorUserID: "g2", subjectUserID: FRIEND }),

    // Stays as guest and as host; s3 is the friend's own and must survive.
    w("stayRequests/s1", { guestUserID: GONE, hostUserID: FRIEND, listingID: "friendHome", status: "completed" }),
    w("stayRequests/s2", { guestUserID: "g1", hostUserID: GONE, listingID: "goneHome", status: "accepted" }),
    w("stayRequests/s3", { guestUserID: "g2", hostUserID: FRIEND, listingID: "friendHome", status: "completed" }),

    w("messages/m1", { senderUserID: GONE, text: "hi" }),
    w("messages/m2", { senderUserID: FRIEND, text: "hello" }),
    w("friendEdges/e1", { userA: GONE, userB: FRIEND }),
    w("friendEdges/e2", { userA: "g2", userB: GONE }),
    w("friendEdges/e3", { userA: FRIEND, userB: "g2" }),
    w("reports/r1", { reporterUserID: GONE }),
    w("reports/r2", { reporterUserID: FRIEND }),
    w("conversations/c1", { participants: [GONE, FRIEND] }),
    w("conversations/c2", { participants: [FRIEND, "g2"] }),
  ]);
}

beforeEach(() => h.reset());
after(() => h.fft.cleanup());

test("deleting an account removes the user's data and leaves everyone else's", async () => {
  await seed();
  await onUserDeleted(h.fft.auth.makeUserRecord({ uid: GONE }));

  // Profile documents are gone and nothing recreated them.
  assert.equal(await exists(`users/${GONE}`), false);
  assert.equal(await exists(`users/${GONE}/private/profile`), false);

  // The listing stays as history, soft-deleted, minus its address and access markers.
  const home = (await h.db.doc("homes/goneHome").get()).data();
  assert.ok(home.deletedAt, "listing should be soft-deleted");
  assert.deepEqual(await ids("homes/goneHome/private"), []);
  assert.deepEqual(await ids("homes/goneHome/accepted"), []);
  assert.deepEqual(h.deletedStoragePrefixes, [`listings/${GONE}/`]);

  // Their access to someone else's address is revoked; the other guest's is not.
  assert.deepEqual(await ids("homes/friendHome/accepted"), ["g2"]);
  assert.equal(await exists("homes/friendHome/private/location"), true);
  assert.equal((await h.db.doc("homes/friendHome").get()).data().deletedAt, undefined);

  assert.deepEqual(await ids("reviews"), ["s3_g2"]);
  assert.deepEqual(await ids("reviews/s1_gone/private"), [], "review feedback was stranded");
  assert.deepEqual(await ids("references"), ["friend_g2"]);
  assert.deepEqual(await ids("stayRequests"), ["s3"]);
  assert.deepEqual(await ids("messages"), ["m2"]);
  assert.deepEqual(await ids("friendEdges"), ["e3"]);
  assert.deepEqual(await ids("reports"), ["r2"]);
  assert.deepEqual(await ids("conversations"), ["c2"]);
});

test("counterparties' trust stats are recomputed without the deleted user", async () => {
  await seed();
  await onUserDeleted(h.fft.auth.makeUserRecord({ uid: GONE }));

  // Left: s3 hosted (completed), and one review from g2 at 3 stars.
  const stats = (await h.db.doc(`users/${FRIEND}`).get()).data().trustStats;
  assert.deepEqual(stats, { staysHosted: 1, staysTaken: 0, reviewCount: 1, averageRating: 3 });
  // g1 had no user doc; the recompute must not mint a stats-only one.
  assert.equal(await exists("users/g1"), false);
});

test("the cascade is safe to retry", async () => {
  await seed();
  const user = h.fft.auth.makeUserRecord({ uid: GONE });
  await onUserDeleted(user);
  await onUserDeleted(user);

  assert.equal(await exists(`users/${GONE}`), false);
  assert.deepEqual(await ids("stayRequests"), ["s3"]);
  assert.deepEqual(await ids("homes/friendHome/accepted"), ["g2"]);
});

test("collections larger than one 500-op batch are drained", async () => {
  const total = 520;
  for (let i = 0; i < total; i += 260) {
    const batch = h.db.batch();
    for (let j = i; j < Math.min(i + 260, total); j++) {
      batch.set(h.db.doc(`messages/m${j}`), { senderUserID: GONE });
    }
    await batch.commit();
  }
  await h.db.doc("messages/keep").set({ senderUserID: FRIEND });

  await onUserDeleted(h.fft.auth.makeUserRecord({ uid: GONE }));

  assert.deepEqual(await ids("messages"), ["keep"]);
});

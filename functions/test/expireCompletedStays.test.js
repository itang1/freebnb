// expireCompletedStays is the nightly sweep that withdraws a guest's access to
// the address once their stay is over, and closes out stays nobody marked complete.
const { test, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { setup } = require("./harness");

const h = setup("freebnb-fn-expire");
const expire = h.fft.wrap(h.functions.expireCompletedStays);

const HOST = "host";
const LISTING = "listing1";

async function seedStay(id, { guest, status, inDays, outDays, extra = {} }) {
  await Promise.all([
    h.db.doc(`stayRequests/${id}`).set({
      hostUserID: HOST,
      guestUserID: guest,
      listingID: LISTING,
      status,
      checkIn: h.daysFromNow(inDays),
      checkOut: h.daysFromNow(outDays),
      ...extra,
    }),
    h.db.doc(`homes/${LISTING}/accepted/${guest}`).set({ guestUserID: guest, requestID: id }),
  ]);
}

const data = async (path) => (await h.db.doc(path).get()).data();
const markers = async () => (await h.db.collection(`homes/${LISTING}/accepted`).get()).docs.map((d) => d.id).sort();

beforeEach(() => h.reset());
after(() => h.fft.cleanup());

test("an ended accepted stay is closed out and its address withdrawn", async () => {
  await seedStay("s1", { guest: "g1", status: "accepted", inDays: -5, outDays: -2 });

  await expire({});

  const s1 = await data("stayRequests/s1");
  assert.equal(s1.status, "completed");
  assert.ok(s1.completedAt);
  assert.ok(s1.accessRevokedAt);
  assert.deepEqual(await markers(), []);
});

test("a stay closed out early keeps its completedAt and only loses the address", async () => {
  const completedAt = h.Timestamp.fromMillis(Date.parse("2026-01-01T00:00:00Z"));
  await seedStay("s1", { guest: "g1", status: "completed", inDays: -5, outDays: -2, extra: { completedAt } });

  await expire({});

  const s1 = await data("stayRequests/s1");
  assert.equal(s1.status, "completed");
  assert.equal(s1.completedAt.toMillis(), completedAt.toMillis());
  assert.ok(s1.accessRevokedAt);
  assert.deepEqual(await markers(), []);
});

test("a guest rebooked at the same listing keeps the address", async () => {
  await seedStay("past", { guest: "g1", status: "accepted", inDays: -5, outDays: -2 });
  await seedStay("next", { guest: "g1", status: "accepted", inDays: 5, outDays: 8 });

  await expire({});

  assert.deepEqual(await markers(), ["g1"]);
  // The past stay is left for a later run, once the next one ends too.
  assert.equal((await data("stayRequests/past")).status, "accepted");
  assert.equal((await data("stayRequests/past")).accessRevokedAt, undefined);
});

test("future, already-revoked and out-of-window stays are left alone", async () => {
  await seedStay("future", { guest: "g1", status: "accepted", inDays: 1, outDays: 4 });
  const revokedAt = h.Timestamp.fromMillis(Date.parse("2026-01-01T00:00:00Z"));
  await seedStay("done", {
    guest: "g2", status: "completed", inDays: -9, outDays: -7, extra: { accessRevokedAt: revokedAt },
  });
  await seedStay("ancient", { guest: "g3", status: "accepted", inDays: -400, outDays: -397 });

  await expire({});

  assert.equal((await data("stayRequests/future")).status, "accepted");
  assert.equal((await data("stayRequests/done")).accessRevokedAt.toMillis(), revokedAt.toMillis());
  assert.equal((await data("stayRequests/ancient")).status, "accepted");
  assert.deepEqual(await markers(), ["g1", "g2", "g3"]);
});

test("running the sweep twice changes nothing the second time", async () => {
  await seedStay("s1", { guest: "g1", status: "accepted", inDays: -5, outDays: -2 });
  await expire({});
  const first = await data("stayRequests/s1");

  await expire({});

  const second = await data("stayRequests/s1");
  assert.equal(second.accessRevokedAt.toMillis(), first.accessRevokedAt.toMillis());
  assert.equal(second.completedAt.toMillis(), first.completedAt.toMillis());
});

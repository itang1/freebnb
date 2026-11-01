// acceptStayRequest owns the double-booking guard: the overlap check and the
// accept commit in one transaction. These run it against the Firestore emulator,
// whose transactions conflict and retry like production's, so concurrent accepts
// race for real.
const { test, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { setup, rejectsWithCode } = require("./harness");

const h = setup("freebnb-fn-accept");
const accept = h.fft.wrap(h.functions.acceptStayRequest);

const HOST = "host";
const LISTING = "listing1";

async function seedListing(extra = {}, availability) {
  await h.db.doc(`homes/${LISTING}`).set({ hostUserID: HOST, title: "Cabin", ...extra });
  if (availability) await h.db.doc(`homes/${LISTING}/private/availability`).set(availability);
}

async function seedRequest(id, { guest, inDays, outDays, status = "pending" }) {
  await h.db.doc(`stayRequests/${id}`).set({
    hostUserID: HOST,
    guestUserID: guest,
    listingID: LISTING,
    status,
    checkIn: h.daysFromNow(inDays),
    checkOut: h.daysFromNow(outDays),
  });
}

async function acceptedIDs() {
  const snap = await h.db.collection("stayRequests").where("status", "==", "accepted").get();
  return snap.docs.map((d) => d.id).sort();
}

async function markerIDs() {
  const snap = await h.db.collection(`homes/${LISTING}/accepted`).get();
  return snap.docs.map((d) => d.id).sort();
}

beforeEach(() => h.reset());
after(() => h.fft.cleanup());

test("two concurrent accepts of overlapping requests: exactly one wins", async () => {
  // Several rounds, since a single race can pass by luck of scheduling.
  for (let round = 0; round < 5; round++) {
    await h.reset();
    await seedListing();
    await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });
    await seedRequest("b", { guest: "g2", inDays: 12, outDays: 15 });

    const results = await Promise.allSettled([
      accept(h.callAs(HOST, { requestID: "a" })),
      accept(h.callAs(HOST, { requestID: "b" })),
    ]);

    const won = results.filter((r) => r.status === "fulfilled");
    const lost = results.filter((r) => r.status === "rejected");
    assert.equal(won.length, 1, `round ${round}: expected one winner, got ${won.length}`);
    assert.equal(lost[0].reason.code, "aborted", `round ${round}: ${lost[0].reason.message}`);

    const accepted = await acceptedIDs();
    assert.equal(accepted.length, 1, `round ${round}: both requests ended up accepted`);
    // The winner's guest, and only theirs, can see the address.
    const winner = accepted[0];
    assert.deepEqual(await markerIDs(), [winner === "a" ? "g1" : "g2"]);
  }
});

test("two concurrent accepts of the same request: one succeeds, one is told it's no longer pending", async () => {
  await seedListing({ coHostUserIDs: ["cohost"] });
  await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });

  const results = await Promise.allSettled([
    accept(h.callAs(HOST, { requestID: "a" })),
    accept(h.callAs("cohost", { requestID: "a" })),
  ]);

  assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
  const lost = results.find((r) => r.status === "rejected");
  assert.equal(lost.reason.code, "failed-precondition");
  assert.deepEqual(await acceptedIDs(), ["a"]);
  assert.deepEqual(await markerIDs(), ["g1"]);
});

test("concurrent accepts of stays that don't overlap both succeed", async () => {
  await seedListing({}, { bufferHours: 0 });
  await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });
  await seedRequest("b", { guest: "g2", inDays: 13, outDays: 15 });

  await Promise.all([
    accept(h.callAs(HOST, { requestID: "a" })),
    accept(h.callAs(HOST, { requestID: "b" })),
  ]);

  assert.deepEqual(await acceptedIDs(), ["a", "b"]);
  assert.deepEqual(await markerIDs(), ["g1", "g2"]);
});

test("the default 24h turnover buffer refuses a back-to-back stay", async () => {
  await seedListing();
  await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });
  await seedRequest("b", { guest: "g2", inDays: 13, outDays: 15 });

  await accept(h.callAs(HOST, { requestID: "a" }));
  await rejectsWithCode(accept(h.callAs(HOST, { requestID: "b" })), "aborted");
  // One clear day between them is enough.
  await seedRequest("c", { guest: "g3", inDays: 14, outDays: 16 });
  await accept(h.callAs(HOST, { requestID: "c" }));
  assert.deepEqual(await acceptedIDs(), ["a", "c"]);
});

test("accepting writes the status, the host note and the address marker together", async () => {
  await seedListing();
  await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });

  assert.deepEqual(await accept(h.callAs(HOST, { requestID: "a", hostNote: "Key under the mat" })), { ok: true });

  const req = (await h.db.doc("stayRequests/a").get()).data();
  assert.equal(req.status, "accepted");
  assert.equal(req.hostNote, "Key under the mat");
  assert.ok(req.updatedAt);
  const marker = (await h.db.doc(`homes/${LISTING}/accepted/g1`).get()).data();
  assert.equal(marker.requestID, "a");
  assert.equal(marker.guestUserID, "g1");
});

test("only the side that is owed the answer may accept", async () => {
  await seedListing({ coHostUserIDs: ["cohost"] });
  await seedRequest("req", { guest: "g1", inDays: 10, outDays: 13 });
  await seedRequest("offer", { guest: "g2", inDays: 20, outDays: 23, status: "offered" });
  await seedRequest("own", { guest: "cohost", inDays: 30, outDays: 33 });

  // A request is the host side's to accept, not the guest's or a stranger's.
  await rejectsWithCode(accept(h.callAs("g1", { requestID: "req" })), "permission-denied");
  await rejectsWithCode(accept(h.callAs("stranger", { requestID: "req" })), "permission-denied");
  // An offer is the guest's, so the host can't accept it for them, nor overwrite the note.
  await rejectsWithCode(accept(h.callAs(HOST, { requestID: "offer" })), "permission-denied");
  await rejectsWithCode(accept(h.callAs("g2", { requestID: "offer", hostNote: "x" })), "invalid-argument");
  // A co-host asking to stay at their own listing can't approve themselves.
  await rejectsWithCode(accept(h.callAs("cohost", { requestID: "own" })), "permission-denied");
  assert.deepEqual(await acceptedIDs(), []);

  await accept(h.callAs("cohost", { requestID: "req" }));
  await accept(h.callAs("g2", { requestID: "offer" }));
  assert.deepEqual(await acceptedIDs(), ["offer", "req"]);
});

test("a deleted listing can't take a booking", async () => {
  await seedListing({ deletedAt: h.Timestamp.now() });
  await seedRequest("a", { guest: "g1", inDays: 10, outDays: 13 });

  await rejectsWithCode(accept(h.callAs(HOST, { requestID: "a" })), "failed-precondition");
  assert.deepEqual(await markerIDs(), []);
});

test("bad callers and bad input are refused before any read", async () => {
  await rejectsWithCode(accept({ data: { requestID: "a" } }), "unauthenticated");
  await rejectsWithCode(
    accept({ data: { requestID: "a" }, auth: { uid: "anon", token: { firebase: { sign_in_provider: "anonymous" } } } }),
    "permission-denied"
  );
  await rejectsWithCode(accept(h.callAs(HOST, {})), "invalid-argument");
  await rejectsWithCode(accept(h.callAs(HOST, { requestID: "a", hostNote: "x".repeat(2001) })), "invalid-argument");
  await rejectsWithCode(accept(h.callAs(HOST, { requestID: "missing" })), "not-found");
});

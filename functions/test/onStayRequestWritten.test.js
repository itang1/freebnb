// onStayRequestWritten does two jobs on every stay-request write: it keeps the
// listing's published booked dates in step with accepted stays, and it sends the
// lifecycle push to whoever is waiting on the answer. FCM is recorded by the
// harness rather than sent.
const { test, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { setup } = require("./harness");

const h = setup("freebnb-fn-stay-written");
const onStayRequestWritten = h.fft.wrap(h.functions.onStayRequestWritten);

const HOST = "host";
const GUEST = "guest";
const LISTING = "listing1";
const DAY = 24 * 60 * 60 * 1000;

// Writes `afterData` (or deletes on null) so the trigger's own reads see it, then
// fires the trigger with the matching before/after change.
async function write(id, beforeData, afterData) {
  const path = `stayRequests/${id}`;
  if (afterData) await h.db.doc(path).set(afterData);
  else await h.db.doc(path).delete();
  const snap = (data) => h.fft.firestore.makeDocumentSnapshot(data ?? {}, path);
  await onStayRequestWritten({
    data: h.fft.makeChange(snap(beforeData), snap(afterData)),
    params: { requestID: id },
  });
}

function stay(status, extra = {}) {
  return {
    hostUserID: HOST,
    guestUserID: GUEST,
    listingID: LISTING,
    listingTitle: "Cabin",
    listingHostName: "Hana",
    status,
    checkIn: h.daysFromNow(10),
    checkOut: h.daysFromNow(13),
    ...extra,
  };
}

async function seedPeople({ hostPrivate = {}, guestPrivate = {} } = {}) {
  await Promise.all([
    h.db.doc(`users/${HOST}`).set({ displayName: "Hana" }),
    h.db.doc(`users/${GUEST}`).set({ displayName: "Gus" }),
    h.db.doc(`users/${HOST}/private/profile`).set({ fcmToken: "host-token", ...hostPrivate }),
    h.db.doc(`users/${GUEST}/private/profile`).set({ fcmToken: "guest-token", ...guestPrivate }),
    h.db.doc(`homes/${LISTING}`).set({ hostUserID: HOST, title: "Cabin" }),
  ]);
}

const millis = (ranges) => (ranges ?? []).map((r) => [r.start.toMillis(), r.end.toMillis()]);

beforeEach(() => h.reset());
after(() => h.fft.cleanup());

test("a new request notifies the host", async () => {
  await seedPeople();
  await write("r1", null, stay("pending"));

  assert.equal(h.pushes.length, 1);
  const [push] = h.pushes;
  assert.equal(push.token, "host-token");
  assert.equal(push.notification.title, "New stay request");
  assert.equal(push.notification.body, "Gus asked to stay for Cabin.");
  assert.deepEqual(push.data, { type: "stay_request", requestID: "r1", role: "host" });
});

test("a muted category, a blocked sender or a missing token sends nothing", async () => {
  await seedPeople({ hostPrivate: { notificationPrefs: { stayRequests: false } } });
  await write("r1", null, stay("pending"));

  await h.db.doc(`users/${HOST}/private/profile`).set({ fcmToken: "host-token", blockedUserIDs: [GUEST] });
  await write("r2", null, stay("pending"));

  await h.db.doc(`users/${HOST}/private/profile`).set({});
  await write("r3", null, stay("pending"));

  assert.deepEqual(h.pushes, []);
});

test("accepting tells the guest and publishes the booked dates with the turnover buffer", async () => {
  await seedPeople();
  const blocked = { start: h.daysFromNow(30), end: h.daysFromNow(31) };
  await h.db.doc(`homes/${LISTING}/private/availability`).set({ blockedDateRanges: [blocked] });

  await write("r1", stay("pending"), stay("accepted"));

  assert.equal(h.pushes.length, 1);
  assert.equal(h.pushes[0].token, "guest-token");
  assert.equal(h.pushes[0].notification.title, "Stay accepted 🎉");

  const availability = (await h.db.doc(`homes/${LISTING}/private/availability`).get()).data();
  const checkIn = h.daysFromNow(10).toMillis();
  const checkOut = h.daysFromNow(13).toMillis();
  // The private half keeps the raw stay...
  assert.deepEqual(millis(availability.bookedDateRanges), [[checkIn, checkOut]]);
  assert.deepEqual(millis(availability.blockedDateRanges), millis([blocked]));
  // ...and the public listing gets the union, with a day of buffer either side.
  const listing = (await h.db.doc(`homes/${LISTING}`).get()).data();
  assert.deepEqual(millis(listing.unavailableDateRanges), [
    [checkIn - DAY, checkOut + DAY],
    ...millis([blocked]),
  ]);
});

test("a host cancelling a confirmed stay gets its own copy and releases the dates", async () => {
  await seedPeople();
  await write("r1", stay("pending"), stay("accepted"));
  h.pushes.length = 0;

  await write("r1", stay("accepted"), stay("cancelled", { cancelledBy: HOST }));

  assert.equal(h.pushes.length, 1);
  assert.equal(h.pushes[0].token, "guest-token");
  assert.equal(h.pushes[0].notification.title, "Your host had to cancel");
  const listing = (await h.db.doc(`homes/${LISTING}`).get()).data();
  assert.deepEqual(listing.unavailableDateRanges, []);
});

test("a guest cancelling tells the host, and an old cancel without cancelledBy tells no one", async () => {
  await seedPeople();
  await write("r1", stay("pending"), stay("cancelled", { cancelledBy: GUEST }));
  assert.equal(h.pushes.length, 1);
  assert.equal(h.pushes[0].token, "host-token");
  assert.equal(h.pushes[0].notification.body, "Gus cancelled their stay for Cabin.");

  await write("r2", stay("pending"), stay("cancelled"));
  assert.equal(h.pushes.length, 1);
});

test("a guest's answer to an offer goes back to the host", async () => {
  await seedPeople();
  await write("o1", null, stay("offered"));
  assert.equal(h.pushes[0].token, "guest-token");
  assert.equal(h.pushes[0].notification.title, "A friend offered you their place");

  await write("o1", stay("offered"), stay("declined"));
  assert.equal(h.pushes.length, 2);
  assert.equal(h.pushes[1].token, "host-token");
  assert.equal(h.pushes[1].notification.title, "Offer update");
});

test("a stay moving to completed refreshes both people's trust stats", async () => {
  await seedPeople();
  await write("r1", stay("accepted"), stay("completed"));

  const host = (await h.db.doc(`users/${HOST}`).get()).data();
  const guest = (await h.db.doc(`users/${GUEST}`).get()).data();
  assert.equal(host.trustStats.staysHosted, 1);
  assert.equal(guest.trustStats.staysTaken, 1);
});

test("deleting an accepted stay releases its booked dates", async () => {
  await seedPeople();
  await write("r1", stay("pending"), stay("accepted"));
  assert.equal((await h.db.doc(`homes/${LISTING}`).get()).data().unavailableDateRanges.length, 1);

  await write("r1", stay("accepted"), null);

  assert.deepEqual((await h.db.doc(`homes/${LISTING}`).get()).data().unavailableDateRanges, []);
});

test("booked dates are never written onto a deleted listing", async () => {
  await seedPeople();
  await h.db.doc(`homes/${LISTING}`).set({ hostUserID: HOST, deletedAt: h.Timestamp.now() });

  await write("r1", stay("pending"), stay("accepted"));

  const listing = (await h.db.doc(`homes/${LISTING}`).get()).data();
  assert.equal(listing.unavailableDateRanges, undefined);
  assert.equal((await h.db.doc(`homes/${LISTING}/private/availability`).get()).exists, false);
});

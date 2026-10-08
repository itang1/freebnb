// The split calendar: `homes/{id}/private/availability`. The public document carries one merged
// `unavailableDateRanges`; the halves live here, because Firestore grants reads per document, so
// publishing both would let anyone subtract one from the other and learn the occupied nights. The
// cases keep the halves apart and the server's half the server's:
//   - an accepted guest, who may read the street, must NOT read this (one accepted stay would make bookings
//   legible);
//   - `bookedDateRanges` derives from accepted stays and must survive every client write, including a delete;
//   - the host's own half stays writable, or the editor stops working.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, setDoc, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const COHOST = "user-cohost";
const GUEST = "user-guest";
const OUTSIDER = "user-outsider";
const LISTING = "listing-1";
const DAY_MS = 86_400_000;

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const availability = (db) => doc(db, "homes", LISTING, "private", "availability");
const location = (db) => doc(db, "homes", LISTING, "private", "location");

const range = (dayOffset) => ({
  start: Timestamp.fromMillis(Date.now() + dayOffset * DAY_MS),
  end: Timestamp.fromMillis(Date.now() + (dayOffset + 1) * DAY_MS),
});

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

/**
 * A listing with a co-host, a calendar carrying both halves, a street address,
 * and GUEST holding an accepted-stay marker. The marker is the point: it is what
 * grants the address, and this file asserts it does not also grant the calendar.
 */
async function seedListing() {
  await seed(async (db) => {
    await setDoc(doc(db, "homes", LISTING), {
      hostUserID: HOST,
      hostName: "Host",
      address: { city: "Town", state: "CA" },
      sleeping: { numGuestRooms: 1 },
      guestPolicy: { maxGuests: 2, maxStayDays: 7 },
      amenities: {},
      allowedViewerIDs: [HOST, GUEST],
      coHostUserIDs: [COHOST],
    });
    await setDoc(availability(db), {
      blockedDateRanges: [range(1)],
      bookedDateRanges: [range(5)],
    });
    await setDoc(location(db), { street: "124 Conch St" });
    await setDoc(doc(db, "homes", LISTING, "accepted", GUEST), { guestUserID: GUEST });
  });
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-availability-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedListing();
});

describe("homes/{id}/private/availability read — who sees the halves", () => {
  it("allows the host", async () => {
    await assertSucceeds(getDoc(availability(as(HOST))));
  });

  // A co-host keeps the calendar current, which they can't do blind.
  it("allows a co-host", async () => {
    await assertSucceeds(getDoc(availability(as(COHOST))));
  });

  // The whole reason the split exists.
  it("denies a guest with an accepted stay", async () => {
    await assertFails(getDoc(availability(as(GUEST))));
  });

  // The control for the case above: same guest and marker, sibling document; otherwise it would prove only
  // "guests can't read subcollections".
  it("still allows that guest the street address", async () => {
    await assertSucceeds(getDoc(location(as(GUEST))));
  });

  it("denies someone with no relationship to the listing", async () => {
    await assertFails(getDoc(availability(as(OUTSIDER))));
  });
});

describe("homes/{id}/private/availability write — the server's half", () => {
  it("allows the host to merge their own blocked half", async () => {
    await assertSucceeds(
      setDoc(availability(as(HOST)), { blockedDateRanges: [range(1), range(2)] }, { merge: true })
    );
  });

  it("allows a co-host to merge the blocked half", async () => {
    await assertSucceeds(
      setDoc(availability(as(COHOST)), { blockedDateRanges: [range(3)] }, { merge: true })
    );
  });

  // The booked half was pinned when a trigger owned it. That isn't deployed, so the host's reconciler
  // now recomputes it from accepted stays and writes here. Managers may write it but it stays managers-only;
  // over-booking their own calendar harms only themselves, and non-managers hit the same gate as the blocked half.
  it("allows the host to write the booked half", async () => {
    await assertSucceeds(
      setDoc(availability(as(HOST)), { bookedDateRanges: [range(9)] }, { merge: true })
    );
  });

  it("allows a co-host to write the booked half", async () => {
    await assertSucceeds(
      setDoc(availability(as(COHOST)), { bookedDateRanges: [range(9)] }, { merge: true })
    );
  });

  it("allows a full overwrite of the calendar by a manager", async () => {
    await assertSucceeds(setDoc(availability(as(HOST)), { blockedDateRanges: [range(1)] }));
  });

  // Deleting is the other way to change a field, so the pin covers it too.
  it("denies the host deleting the document to shed its bookings", async () => {
    await assertFails(deleteDoc(availability(as(HOST))));
  });

  it("denies an outsider writing the calendar at all", async () => {
    await assertFails(
      setDoc(availability(as(OUTSIDER)), { blockedDateRanges: [range(4)] }, { merge: true })
    );
  });

  it("denies an unknown field on the calendar", async () => {
    await assertFails(
      setDoc(availability(as(HOST)), { awayUntil: Timestamp.now() }, { merge: true })
    );
  });

  // The turnover buffer: stored here, not on the public listing, so a guest can't subtract a known buffer from an
  // unavailable stretch. The rule validates the field but can't range-check it (no loops); the double-booking
  // and buffer guards live in the accept path.
  it("allows the host to set a valid turnover buffer", async () => {
    await assertSucceeds(
      setDoc(availability(as(HOST)), { bufferHours: 48 }, { merge: true })
    );
  });

  it("allows a co-host to set the buffer", async () => {
    await assertSucceeds(
      setDoc(availability(as(COHOST)), { bufferHours: 0 }, { merge: true })
    );
  });

  it("denies a buffer beyond the ceiling", async () => {
    await assertFails(
      setDoc(availability(as(HOST)), { bufferHours: 169 }, { merge: true })
    );
  });

  it("denies a negative buffer", async () => {
    await assertFails(
      setDoc(availability(as(HOST)), { bufferHours: -1 }, { merge: true })
    );
  });

  it("denies a non-integer buffer", async () => {
    await assertFails(
      setDoc(availability(as(HOST)), { bufferHours: 12.5 }, { merge: true })
    );
  });

  it("denies an outsider setting the buffer", async () => {
    await assertFails(
      setDoc(availability(as(OUTSIDER)), { bufferHours: 24 }, { merge: true })
    );
  });
});

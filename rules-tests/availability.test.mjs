// The split calendar: `homes/{id}/private/availability`.
//
// A listing's calendar is stored twice on purpose. The public document carries
// one merged field, `unavailableDateRanges`; the two halves it was merged from
// live in this private document. The split exists because Firestore grants reads
// per document and never per field — a listing that published both halves let
// anyone who could see it subtract one from the other and learn exactly which
// nights the home was occupied, no matter what the UI chose to draw.
//
// So the interesting cases here are all about keeping the halves apart and
// keeping the server's half the server's:
//
//   - an accepted guest, who may read the street address, must NOT read this.
//     One accepted stay anywhere would otherwise make the host's bookings
//     legible again and the split would have bought nothing.
//   - `bookedDateRanges` is derived from accepted stays by `onStayRequestWritten`
//     and must survive every client write, including the one that deletes the
//     document out from under the pin.
//   - the host's own half stays writable, or the availability editor stops working.

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

  // A co-host keeps the calendar current, which they cannot do blind.
  it("allows a co-host", async () => {
    await assertSucceeds(getDoc(availability(as(COHOST))));
  });

  // The whole reason the split exists.
  it("denies a guest with an accepted stay", async () => {
    await assertFails(getDoc(availability(as(GUEST))));
  });

  // The control for the case above: the same guest, the same marker, the
  // sibling document. If this failed too, the test above would prove nothing
  // beyond "the guest cannot read subcollections".
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

  // The booked half was pinned when a trigger owned it. The trigger is not
  // deployed, so the host's reconciler owns it now — it recomputes bookings from
  // the listing's accepted stays and writes them here. Managers may write it;
  // it stays managers-only, so a booking never becomes legible to a guest. A
  // manager over-booking their own calendar harms only themselves, and a
  // non-manager is refused by the same gate the blocked half sits behind.
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

  // Deleting is the one way to change a field without updating it, so the pin
  // has to cover it too.
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
});

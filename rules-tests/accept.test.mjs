// Accepting a stay used to be the callable's alone, and the rules said so:
// `allow create: if false` on the address-disclosure marker, and no accept
// branch on the stay request at all. The callable is not deployed in
// production, so that combination did not protect acceptance — it prevented it.
//
// The host path now runs on the client. These tests pin what that did *not*
// open up, which is the whole point of writing them:
//   - only the host side may accept, and only a pending request;
//   - accepting may not rewrite the dates, the parties, or the listing;
//   - a guest may not accept their own request (the self-approval hole);
//   - an offer still may not be client-accepted — that path keeps the callable;
//   - the address grant cannot be forged: not without an accepted request, not
//     for a request belonging to someone else, not pointed at another listing,
//     and not by the guest who would benefit from it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, serverTimestamp, Timestamp, writeBatch } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const COHOST = "user-cohost";
const GUEST = "user-guest";
const STRANGER = "user-stranger";
const LISTING = "listing-1";
const REQUEST = "request-1";

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

const day = (n) => Timestamp.fromMillis(Date.UTC(2026, 8, n));

function listingBody(extra = {}) {
  return {
    id: LISTING,
    hostUserID: HOST,
    hostName: "Host",
    address: { city: "Portland", state: "OR", zip: "97201" },
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities: { hasWifi: true },
    allowedViewerIDs: [HOST, COHOST, GUEST],
    coHostUserIDs: [COHOST],
    createdAt: Timestamp.now(),
    ...extra,
  };
}

function requestBody(extra = {}) {
  return {
    id: REQUEST,
    listingID: LISTING,
    listingCity: "Portland",
    listingHostName: "Host",
    hostUserID: HOST,
    guestUserID: GUEST,
    checkIn: day(3),
    checkOut: day(6),
    status: "pending",
    createdAt: Timestamp.now(),
    ...extra,
  };
}

/** The status half of an acceptance, exactly as the client writes it. */
const acceptFields = { status: "accepted", updatedAt: serverTimestamp() };

/** The grant half, exactly as the client writes it. */
const markerFields = (extra = {}) => ({
  requestID: REQUEST,
  guestUserID: GUEST,
  createdAt: serverTimestamp(),
  ...extra,
});

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-accept-tests",
    // No host/port: every other file in this directory lets the emulator be
    // discovered from FIRESTORE_EMULATOR_HOST, which `emulators:exec` sets to
    // whatever port it actually booted on. Naming one here pinned this file to a
    // port nothing was listening on, so `before` hung and the runner cancelled
    // every test in the file with "did not finish before its parent" — which
    // reads like a suite-wide breakage rather than a wrong address.
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(async () => { await testEnv.cleanup(); });

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seed(async (db) => {
    await setDoc(doc(db, "homes", LISTING), listingBody());
    await setDoc(doc(db, "stayRequests", REQUEST), requestBody());
  });
});

describe("accepting a pending request from the client", () => {
  it("allows the host to move a pending request to accepted", async () => {
    await assertSucceeds(updateDoc(doc(as(HOST), "stayRequests", REQUEST), acceptFields));
  });

  it("allows a co-host to accept, same as answering any other way", async () => {
    await assertSucceeds(updateDoc(doc(as(COHOST), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses the guest accepting their own request", async () => {
    await assertFails(updateDoc(doc(as(GUEST), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses a stranger", async () => {
    await assertFails(updateDoc(doc(as(STRANGER), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses accepting a request that is not pending", async () => {
    await seed((db) => setDoc(doc(db, "stayRequests", REQUEST), requestBody({ status: "declined" })));
    await assertFails(updateDoc(doc(as(HOST), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses the host accepting their own offer on the guest's behalf", async () => {
    // An offer is the guest's to accept. The host writing accepted here would be
    // the self-approval hole on the offer path.
    await seed((db) => setDoc(doc(db, "stayRequests", REQUEST), requestBody({ status: "offered", initiatedBy: HOST })));
    await assertFails(updateDoc(doc(as(HOST), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses moving the dates while accepting", async () => {
    await assertFails(updateDoc(doc(as(HOST), "stayRequests", REQUEST), {
      ...acceptFields, checkIn: day(10), checkOut: day(14),
    }));
  });

  it("refuses swapping the guest while accepting", async () => {
    await assertFails(updateDoc(doc(as(HOST), "stayRequests", REQUEST), {
      ...acceptFields, guestUserID: STRANGER,
    }));
  });

  it("refuses repointing the request at another listing while accepting", async () => {
    await assertFails(updateDoc(doc(as(HOST), "stayRequests", REQUEST), {
      ...acceptFields, listingID: "listing-2",
    }));
  });
});

describe("accepting a host's offer from the guest's side", () => {
  const offer = () =>
    seed((db) => setDoc(doc(db, "stayRequests", REQUEST), requestBody({ status: "offered", initiatedBy: HOST })));

  it("allows the guest to move their offer to accepted", async () => {
    await offer();
    await assertSucceeds(updateDoc(doc(as(GUEST), "stayRequests", REQUEST), acceptFields));
  });

  it("allows the guest to add their own note while accepting", async () => {
    await offer();
    await assertSucceeds(updateDoc(doc(as(GUEST), "stayRequests", REQUEST), {
      ...acceptFields, guestNote: "can't wait",
    }));
  });

  it("refuses a stranger accepting the offer", async () => {
    await offer();
    await assertFails(updateDoc(doc(as(STRANGER), "stayRequests", REQUEST), acceptFields));
  });

  it("refuses the guest writing the host's note while accepting", async () => {
    await offer();
    await assertFails(updateDoc(doc(as(GUEST), "stayRequests", REQUEST), {
      ...acceptFields, hostNote: "words in the host's mouth",
    }));
  });

  it("refuses the guest moving the dates while accepting", async () => {
    await offer();
    await assertFails(updateDoc(doc(as(GUEST), "stayRequests", REQUEST), {
      ...acceptFields, checkIn: day(10), checkOut: day(14),
    }));
  });

  it("lets the guest write their own address grant in the accepting commit", async () => {
    await offer();
    const db = as(GUEST);
    const batch = writeBatch(db);
    batch.update(doc(db, "stayRequests", REQUEST), acceptFields);
    batch.set(doc(db, "homes", LISTING, "accepted", GUEST), markerFields());
    await assertSucceeds(batch.commit());
  });

  it("refuses the guest granting an address without accepting", async () => {
    await offer();
    await assertFails(setDoc(doc(as(GUEST), "homes", LISTING, "accepted", GUEST), markerFields()));
  });
});

describe("the address grant", () => {
  /** Acceptance and grant in one commit, which is how the client writes them. */
  function acceptBatch(db, { markerExtra = {}, guestID = GUEST } = {}) {
    const batch = writeBatch(db);
    batch.update(doc(db, "stayRequests", REQUEST), acceptFields);
    batch.set(doc(db, "homes", LISTING, "accepted", guestID), markerFields(markerExtra));
    return batch.commit();
  }

  it("allows the host to grant it in the same commit as the acceptance", async () => {
    await assertSucceeds(acceptBatch(as(HOST)));
  });

  it("allows a co-host the same", async () => {
    await assertSucceeds(acceptBatch(as(COHOST)));
  });

  it("refuses a grant with no acceptance in the commit", async () => {
    await assertFails(setDoc(doc(as(HOST), "homes", LISTING, "accepted", GUEST), markerFields()));
  });

  it("refuses the guest granting themselves the address", async () => {
    await assertFails(acceptBatch(as(GUEST)));
  });

  it("refuses a stranger granting themselves the address", async () => {
    await assertFails(acceptBatch(as(STRANGER), { guestID: STRANGER }));
  });

  it("refuses a grant naming a different guest than the request", async () => {
    // The request is GUEST's; the marker tries to let STRANGER in on it.
    await assertFails(acceptBatch(as(HOST), { guestID: STRANGER }));
  });

  it("refuses a grant pointed at a request for another listing", async () => {
    await seed((db) =>
      setDoc(doc(db, "stayRequests", "request-elsewhere"), requestBody({
        id: "request-elsewhere", listingID: "listing-2", status: "accepted",
      }))
    );
    await assertFails(
      setDoc(doc(as(HOST), "homes", LISTING, "accepted", GUEST),
        markerFields({ requestID: "request-elsewhere" }))
    );
  });

  it("refuses a grant carrying extra fields", async () => {
    const db = as(HOST);
    const batch = writeBatch(db);
    batch.update(doc(db, "stayRequests", REQUEST), acceptFields);
    batch.set(doc(db, "homes", LISTING, "accepted", GUEST), markerFields({ note: "smuggled" }));
    await assertFails(batch.commit());
  });
});

describe("the listing's published calendar", () => {
  it("allows the host to add the booked range to unavailableDateRanges", async () => {
    await assertSucceeds(updateDoc(doc(as(HOST), "homes", LISTING), {
      unavailableDateRanges: [{ start: day(3), end: day(6) }],
    }));
  });

  it("still refuses a guest writing the listing's calendar", async () => {
    await assertFails(updateDoc(doc(as(GUEST), "homes", LISTING), {
      unavailableDateRanges: [{ start: day(3), end: day(6) }],
    }));
  });

  it("still refuses anyone publishing the split halves on the public document", async () => {
    await assertFails(updateDoc(doc(as(HOST), "homes", LISTING), {
      bookedDateRanges: [{ start: day(3), end: day(6) }],
    }));
  });

  it("lets the host reconcile the private booked half", async () => {
    // Previously pinned against every client because the trigger owned it. The
    // host's reconciler owns it now, so this must be allowed — and it is still
    // managers-only, which is what keeps it off a guest's read.
    await seed((db) =>
      setDoc(doc(db, "homes", LISTING, "private", "availability"), {
        blockedDateRanges: [], bookedDateRanges: [],
      })
    );
    await assertSucceeds(updateDoc(doc(as(HOST), "homes", LISTING, "private", "availability"), {
      bookedDateRanges: [{ start: day(3), end: day(6) }],
    }));
  });

  it("still refuses a guest reading the private availability document", async () => {
    await seed((db) =>
      setDoc(doc(db, "homes", LISTING, "private", "availability"), {
        blockedDateRanges: [], bookedDateRanges: [{ start: day(3), end: day(6) }],
      })
    );
    // Even an accepted guest: the split's whole purpose is that a booking never
    // becomes legible as distinct from a blocked day.
    await seed((db) => setDoc(doc(db, "homes", LISTING, "accepted", GUEST), markerFields()));
    const { getDoc } = await import("firebase/firestore");
    await assertFails(getDoc(doc(as(GUEST), "homes", LISTING, "private", "availability")));
  });
});

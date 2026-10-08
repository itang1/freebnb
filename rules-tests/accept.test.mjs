// Accepting a stay was the callable's alone (`allow create: if false` on the address marker, no
// accept branch on the request), but with the callable undeployed that prevented acceptance.
// The host path now runs on the client. These pin what that did *not* open up:
//   - only the host side may accept, and only a pending request;
//   - accepting can't rewrite the dates, parties or listing;
//   - a guest can't accept their own request (self-approval);
//   - an offer still can't be client-accepted by the host;
//   - the address grant can't be forged: without an accepted request, for someone else's request,
//     pointed at another listing, or by the guest who'd benefit.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, setDoc, updateDoc, serverTimestamp, Timestamp, writeBatch } from "firebase/firestore";

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
    // No host/port: other files discover the emulator from FIRESTORE_EMULATOR_HOST, and naming
    // one here left `before` hanging and the runner cancelling every test with a misleading error.
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
    // An offer is the guest's to accept; the host writing accepted is the self-approval hole.
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

// Read, create and delete on the marker must ask the same question. They drifted once: `create` moved
// to `isListingManager` while read and delete stayed on `isListingHost`, so a co-host could issue a
// grant they couldn't read back and cancel a stay whose address they couldn't revoke.
describe("the address grant — revoking and reading it back", () => {
  /** A stay already accepted, with the guest holding the address. */
  async function seedAccepted() {
    await seed(async (db) => {
      await setDoc(doc(db, "stayRequests", REQUEST), requestBody({ status: "accepted" }));
      await setDoc(doc(db, "homes", LISTING, "accepted", GUEST), {
        requestID: REQUEST,
        guestUserID: GUEST,
        createdAt: Timestamp.now(),
      });
    });
  }

  const markerDoc = (db) => doc(db, "homes", LISTING, "accepted", GUEST);

  it("lets the host read a grant they issued", async () => {
    await seedAccepted();
    await assertSucceeds(getDoc(markerDoc(as(HOST))));
  });

  it("lets a co-host read a grant they could have issued", async () => {
    await seedAccepted();
    await assertSucceeds(getDoc(markerDoc(as(COHOST))));
  });

  it("lets the guest read their own grant", async () => {
    await seedAccepted();
    await assertSucceeds(getDoc(markerDoc(as(GUEST))));
  });

  it("refuses a stranger reading someone else's grant", async () => {
    await seedAccepted();
    await assertFails(getDoc(markerDoc(as(STRANGER))));
  });

  it("lets the guest hand the address back", async () => {
    await seedAccepted();
    await assertSucceeds(deleteDoc(markerDoc(as(GUEST))));
  });

  it("refuses a stranger revoking a grant", async () => {
    await seedAccepted();
    await assertFails(deleteDoc(markerDoc(as(STRANGER))));
  });

  // The drift's actual break: `updateStatus` sends the cancel and revoke as one atomic batch, so a
  // co-host who could cancel but not revoke failed outright. Written as that batch, since two writes would pass.
  function cancelBatch(db) {
    const batch = writeBatch(db);
    batch.update(doc(db, "stayRequests", REQUEST), {
      status: "cancelled",
      cancelledBy: HOST,
      updatedAt: serverTimestamp(),
    });
    batch.delete(doc(db, "homes", LISTING, "accepted", GUEST));
    return batch.commit();
  }

  it("lets the host cancel an accepted stay and revoke the address in one commit", async () => {
    await seedAccepted();
    await assertSucceeds(cancelBatch(as(HOST)));
  });

  it("lets a co-host do the same", async () => {
    await seedAccepted();
    await assertSucceeds(cancelBatch(as(COHOST)));
  });

  it("still refuses a stranger cancelling and revoking", async () => {
    await seedAccepted();
    await assertFails(cancelBatch(as(STRANGER)));
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
    // Previously pinned because a trigger owned it; the host's reconciler does now, so this must be allowed
    // (still managers-only).
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
    // Even an accepted guest: a booking must never become legible as distinct from a blocked day.
    await seed((db) => setDoc(doc(db, "homes", LISTING, "accepted", GUEST), markerFields()));
    const { getDoc } = await import("firebase/firestore");
    await assertFails(getDoc(doc(as(GUEST), "homes", LISTING, "private", "availability")));
  });
});

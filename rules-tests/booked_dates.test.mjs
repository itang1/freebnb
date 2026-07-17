// bookedDateRanges is the server-owned half of a listing's availability: the
// dates its accepted stays have taken, published so guests see them as
// "unavailable" without seeing that the home is occupied. The rules deliberately
// do NOT pin it against client writes — the client round-trips it on every save
// (the repository replaces the whole document), and a tampered value only changes
// this listing's own display. The real double-booking guard is the
// acceptStayRequest transaction, which reads the stays themselves, not this field.
//
// So what the rules owe it is narrow, and that is what's pinned here:
//   - it's an allowed key, so a host's save that carries it back doesn't fail;
//   - it's capped, because it rides every feed document;
//   - a co-host's save carries it too, so their edits don't fail on it either.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const COHOST = "user-cohost";
const LISTING = "listing-1";

let testEnv;

const asHost = () => testEnv.authenticatedContext(HOST).firestore();
const asCoHost = () => testEnv.authenticatedContext(COHOST).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

function listingBody(extra = {}) {
  return {
    id: LISTING,
    hostUserID: HOST,
    hostName: "Host",
    address: { city: "Portland", state: "OR", zip: "97201" },
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities: { hasWifi: true },
    allowedViewerIDs: [HOST, COHOST],
    coHostUserIDs: [],
    createdAt: Timestamp.now(),
    ...extra,
  };
}

async function seedListing(extra = {}) {
  await seed((db) => setDoc(doc(db, "homes", LISTING), listingBody(extra)));
}

const listingDoc = (db) => doc(db, "homes", LISTING);
const range = () => ({ start: Timestamp.now(), end: Timestamp.now() });

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-booked-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("homes/{id} — bookedDateRanges", () => {
  // Writes are exercised through update, not create: the create rule also demands
  // full membership and a server-stamped createdAt, which would mask whether the
  // field itself is allowed. Seeding then updating isolates that.
  it("accepts booked ranges written onto a listing", async () => {
    await seedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), { bookedDateRanges: [range()] })
    );
  });

  // The field the trigger owns must survive the host's own edits: the client
  // decodes it and writes it straight back, and a save that carried it must pass.
  it("lets the host carry booked ranges through an edit", async () => {
    await seedListing({ bookedDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), {
        description: "Now with a hammock.",
        bookedDateRanges: [range()],
      })
    );
  });

  // A co-host's save round-trips every field too, so booked ranges has to be a key
  // they may write or their unrelated edits would fail on it.
  it("lets a co-host carry booked ranges through an edit", async () => {
    await seedListing({ coHostUserIDs: [COHOST], bookedDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        description: "Co-host tidied the copy.",
        bookedDateRanges: [range()],
      })
    );
  });

  // It rides every feed document, so it carries the same 100-entry cap as blocked
  // ranges. 101 must be rejected — via update, so the failure is the cap and not
  // the create rule's other demands.
  it("rejects more booked ranges than the cap", async () => {
    await seedListing();
    const tooMany = Array.from({ length: 101 }, range);
    await assertFails(
      updateDoc(listingDoc(asHost()), { bookedDateRanges: tooMany })
    );
  });
});

// unavailableDateRanges is the one availability field the readable listing carries: the union of
// host-closed days and accepted-stay days. The halves live in `private/availability`
// (availability.test.mjs). The merge is the privacy boundary, since publishing both would let
// anyone subtract one from the other and learn the occupied nights.
//
// The rules deliberately don't pin it against client writes (the client round-trips it on every
// save, and a tampered value only changes this listing's display; the real guard reads the stays).
// What's pinned is narrow:
//   - it's an allowed key, so a host's save carrying it back doesn't fail;
//   - it's capped at the sum of the two former caps, since it rides every feed document;
//   - a co-host's save carries it too;
//   - the two old field names are refused, so a modified client can't put the halves back.

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

describe("homes/{id} — unavailableDateRanges", () => {
  // Writes go through update, not create, whose other demands (full membership, server createdAt) would mask whether the field is allowed.
  it("accepts merged ranges written onto a listing", async () => {
    await seedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), { unavailableDateRanges: [range()] })
    );
  });

  // The field the trigger republishes must survive the host's own edits: the client decodes it and writes it back.
  it("lets the host carry merged ranges through an edit", async () => {
    await seedListing({ unavailableDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), {
        description: "Now with a hammock.",
        unavailableDateRanges: [range()],
      })
    );
  });

  // A co-host's save round-trips every field, so the merged field must be a key they may write.
  it("lets a co-host carry merged ranges through an edit", async () => {
    await seedListing({ coHostUserIDs: [COHOST], unavailableDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        description: "Co-host tidied the copy.",
        unavailableDateRanges: [range()],
      })
    );
  });

  // It rides every feed document, so it carries the sum of the two former caps; 201 is rejected via update so the failure is the cap.
  it("rejects more merged ranges than the cap", async () => {
    await seedListing();
    const tooMany = Array.from({ length: 201 }, range);
    await assertFails(
      updateDoc(listingDoc(asHost()), { unavailableDateRanges: tooMany })
    );
  });

  // The split, enforced from this side: neither half may reappear under its old name.
  it("refuses the blocked half by its old name", async () => {
    await seedListing();
    await assertFails(
      updateDoc(listingDoc(asHost()), { blockedDateRanges: [range()] })
    );
  });

  it("refuses the booked half by its old name", async () => {
    await seedListing();
    await assertFails(
      updateDoc(listingDoc(asHost()), { bookedDateRanges: [range()] })
    );
  });
});

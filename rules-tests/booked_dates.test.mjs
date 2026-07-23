// unavailableDateRanges is the one availability field the world-readable listing
// carries: the union of the days a host has closed by hand and the days an
// accepted stay has taken. The two halves it was merged from used to sit on this
// document under their own names; they live in `private/availability` now, and
// availability.test.mjs covers that document and the pin that keeps its
// server-owned half server-owned.
//
// The merge is the privacy boundary. Firestore grants reads per document and
// never per field, so publishing both halves let anyone who could see the
// listing subtract one from the other and learn which nights the home was
// occupied. What is left here is a single field that cannot be taken apart.
//
// The rules deliberately do NOT pin it against client writes: the client
// round-trips it on every save (the repository replaces the whole document), and
// a tampered value only changes this listing's own display. The real
// double-booking guard reads the stays themselves, not this field.
//
// So what the rules owe it is narrow, and that is what's pinned here:
//   - it's an allowed key, so a host's save that carries it back doesn't fail;
//   - it's capped — at the sum of the two former caps, since it is their union —
//     because it rides every feed document;
//   - a co-host's save carries it too, so their edits don't fail on it either;
//   - the two old field names are refused, which is what stops a modified client
//     from putting the halves back and undoing the split.

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
  // Writes are exercised through update, not create: the create rule also demands
  // full membership and a server-stamped createdAt, which would mask whether the
  // field itself is allowed. Seeding then updating isolates that.
  it("accepts merged ranges written onto a listing", async () => {
    await seedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), { unavailableDateRanges: [range()] })
    );
  });

  // The field the trigger republishes must survive the host's own edits: the
  // client decodes it and writes it straight back, and a save that carried it
  // must pass.
  it("lets the host carry merged ranges through an edit", async () => {
    await seedListing({ unavailableDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), {
        description: "Now with a hammock.",
        unavailableDateRanges: [range()],
      })
    );
  });

  // A co-host's save round-trips every field too, so the merged field has to be a
  // key they may write or their unrelated edits would fail on it.
  it("lets a co-host carry merged ranges through an edit", async () => {
    await seedListing({ coHostUserIDs: [COHOST], unavailableDateRanges: [range()] });
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        description: "Co-host tidied the copy.",
        unavailableDateRanges: [range()],
      })
    );
  });

  // It rides every feed document, so it carries the sum of the two former
  // per-half caps. 201 must be rejected — via update, so the failure is the cap
  // and not the create rule's other demands.
  it("rejects more merged ranges than the cap", async () => {
    await seedListing();
    const tooMany = Array.from({ length: 201 }, range);
    await assertFails(
      updateDoc(listingDoc(asHost()), { unavailableDateRanges: tooMany })
    );
  });

  // The split, enforced from this side. Neither half may reappear on the
  // world-readable document under its old name, however the write is dressed up.
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

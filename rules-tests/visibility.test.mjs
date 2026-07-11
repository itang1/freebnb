// Listings are friends-only: readable by the host, the co-hosts, and the users
// named in `allowedViewerIDs` (the host's accepted friends), and nobody else.
// The legacy `visibility` field is accepted on writes for old-client
// compatibility but must never widen the audience — a document stamped
// 'everyone' or 'friendsOfFriends' is exactly as private as any other. These
// tests pin that: if a rules change ever honors `visibility` again, they fail.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const FRIEND = "user-friend";
const STRANGER = "user-stranger";
const LISTING = "listing-1";

let testEnv;

const asHost = () => testEnv.authenticatedContext(HOST).firestore();
const asFriend = () => testEnv.authenticatedContext(FRIEND).firestore();
const asStranger = () => testEnv.authenticatedContext(STRANGER).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

/** A valid listing document whose ACL admits the host and one friend. */
function listingBody(extra = {}) {
  return {
    id: LISTING,
    hostUserID: HOST,
    hostName: "Host",
    address: { city: "Portland", state: "OR", zip: "97201" },
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities: { hasWifi: true },
    allowedViewerIDs: [HOST, FRIEND],
    coHostUserIDs: [],
    createdAt: Timestamp.now(),
    ...extra,
  };
}

async function seedListing(extra = {}) {
  await seed((db) => setDoc(doc(db, "homes", LISTING), listingBody(extra)));
}

const listingDoc = (db) => doc(db, "homes", LISTING);

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-visibility-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("homes/{id} — friends-only reads", () => {
  it("lets the host read their own listing even with an empty ACL", async () => {
    await seedListing({ allowedViewerIDs: [HOST] });
    await assertSucceeds(getDoc(listingDoc(asHost())));
  });

  it("lets a friend named in the ACL read the listing", async () => {
    await seedListing();
    await assertSucceeds(getDoc(listingDoc(asFriend())));
  });

  it("hides the listing from a signed-in stranger", async () => {
    await seedListing();
    await assertFails(getDoc(listingDoc(asStranger())));
  });

  // The legacy tiers. Documents stamped by old clients or predating the
  // migration must not be world-readable.
  it("ignores legacy visibility 'everyone': a stranger still cannot read", async () => {
    await seedListing({ visibility: "everyone" });
    await assertFails(getDoc(listingDoc(asStranger())));
  });

  it("ignores legacy visibility 'friendsOfFriends': outside the ACL means no read", async () => {
    await seedListing({ visibility: "friendsOfFriends" });
    await assertFails(getDoc(listingDoc(asStranger())));
  });

  it("hides a legacy document with no ACL at all from a stranger", async () => {
    const body = listingBody({ visibility: "everyone" });
    delete body.allowedViewerIDs;
    await seed((db) => setDoc(doc(db, "homes", LISTING), body));
    await assertFails(getDoc(listingDoc(asStranger())));
  });
});

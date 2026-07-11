// Listings are friends-only: readable by the host, the co-hosts, and the users
// named in `allowedViewerIDs` (the host's accepted friends), and nobody else.
// The legacy `visibility` tier field is dead: any write carrying it is
// rejected by the key allowlist, and a pre-migration document that still has
// one is exactly as private as any other. These tests pin both ends: if a
// rules change ever accepts or honors `visibility` again, they fail.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  where,
} from "firebase/firestore";

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

  // A pre-migration document (no ACL, possibly a stale tier stamp) must not be
  // world-readable while it waits for scripts/migrate_friends_only.js.
  it("hides a pre-migration document with no ACL at all from a stranger", async () => {
    const body = listingBody({ visibility: "everyone" });
    delete body.allowedViewerIDs;
    await seed((db) => setDoc(doc(db, "homes", LISTING), body));
    await assertFails(getDoc(listingDoc(asStranger())));
  });
});

describe("homes/{id} — the legacy visibility field is rejected on writes", () => {
  // `createdAt` must be serverTimestamp() on a create, so the passing sibling
  // below is what proves the rejection here is about `visibility` and not some
  // unrelated validation failure.
  it("rejects a create that still carries the field", async () => {
    await assertFails(
      setDoc(
        doc(asHost(), "homes", "listing-2"),
        listingBody({ id: "listing-2", visibility: "friendsOnly", createdAt: serverTimestamp() })
      )
    );
  });

  it("allows the otherwise-identical create without it", async () => {
    await assertSucceeds(
      setDoc(
        doc(asHost(), "homes", "listing-2"),
        listingBody({ id: "listing-2", createdAt: serverTimestamp() })
      )
    );
  });

  it("rejects the host stamping it back onto an existing listing", async () => {
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { visibility: "everyone" }));
  });
});

describe("homes — list queries", () => {
  // The feed's one query. Rules reject a query wholesale unless every possible
  // match provably passes the read gate, so this pins that the ACL filter is
  // still provably safe…
  it("allows the feed query: allowedViewerIDs contains me", async () => {
    await seedListing();
    const feed = query(collection(asFriend(), "homes"), where("allowedViewerIDs", "array-contains", FRIEND));
    await assertSucceeds(getDocs(feed));
  });

  // …and that nothing broader is. An unfiltered list would leak every listing
  // on the platform to any signed-in account.
  it("rejects an unfiltered list of all homes", async () => {
    await seedListing();
    await assertFails(getDocs(collection(asStranger(), "homes")));
  });
});

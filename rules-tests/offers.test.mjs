// Host-initiated offers: the host proposes, the guest answers. This is the first write where the
// *host* creates a stay document, inverting the create rule's assumption that the caller is the
// guest. The cases are forgeries the old shape would have waved through:
//   - a host manufacturing a "pending" request from a friend who never asked (self-accept, mint trust stats);
//   - a guest posting an "offered" document to look invited;
//   - a host offering to someone who can't see the listing (the friends-only boundary);
//   - a host writing the guest's own words (note, party size).
// Acceptance isn't tested here; the double-booking guard is an admin transaction.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, serverTimestamp, setDoc, updateDoc, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const FRIEND = "user-friend";
const STRANGER = "user-stranger";
const LISTING = "listing-1";
const OFFER = "offer-1";
const DAY_MS = 86_400_000;

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

/** An accepted friend edge, under the canonical sorted id. */
async function seedFriendship(a, b) {
  const [userA, userB] = [a, b].sort();
  await seed((db) =>
    setDoc(doc(db, "friendEdges", `${userA}_${userB}`), {
      userA,
      userB,
      status: "accepted",
      initiator: userA,
    })
  );
}

/**
 * A live listing hosted by HOST and shared with FRIEND, who is an actual friend.
 *
 * The friend edge is part of the fixture, not decoration. This file used to model
 * "friend" as nothing but membership in `allowedViewerIDs`, which is the same
 * conflation the offer rule itself used to make: the host authors that array, so
 * it could never be evidence of anything about the person in it. The rule now
 * asks the friend graph directly, and the fixture has to supply one.
 */
async function seedListing(extra = {}) {
  await seedFriendship(HOST, FRIEND);
  await seed((db) =>
    setDoc(doc(db, "homes", LISTING), {
      hostUserID: HOST,
      hostName: "Host",
      address: { city: "Town", state: "CA" },
      sleeping: { numGuestRooms: 1 },
      guestPolicy: { maxGuests: 2, maxStayDays: 7 },
      amenities: {},
      allowedViewerIDs: [HOST, FRIEND],
      ...extra,
    })
  );
}

async function seedBlock(ownerID, blockedID) {
  await seed((db) =>
    setDoc(doc(db, "users", ownerID, "private", "profile"), {
      blockedUserIDs: [blockedID],
    })
  );
}

async function seedOffer(status = "offered", extra = {}) {
  await seed((db) =>
    setDoc(doc(db, "stayRequests", OFFER), {
      id: OFFER,
      listingID: LISTING,
      listingCity: "Town",
      listingHostName: "Host",
      hostUserID: HOST,
      guestUserID: FRIEND,
      checkIn: Timestamp.fromMillis(Date.now() + 5 * DAY_MS),
      checkOut: Timestamp.fromMillis(Date.now() + 8 * DAY_MS),
      status,
      initiatedBy: HOST,
      ...extra,
    })
  );
}

/** An offer exactly as the host's client sends one. */
function offerBody(overrides = {}) {
  return {
    id: OFFER,
    listingID: LISTING,
    listingCity: "Town",
    listingHostName: "Host",
    hostUserID: HOST,
    guestUserID: FRIEND,
    checkIn: Timestamp.fromMillis(Date.now() + 2 * DAY_MS),
    checkOut: Timestamp.fromMillis(Date.now() + 4 * DAY_MS),
    status: "offered",
    initiatedBy: HOST,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

const createOffer = (uid, overrides) =>
  setDoc(doc(as(uid), "stayRequests", OFFER), offerBody(overrides));

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-offers-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("stayRequests/{id} create — a host offering their place", () => {
  // The control: a rule denying everything would pass the rest.
  it("allows a host offering to a friend the listing is shared with", async () => {
    await seedListing();
    await assertSucceeds(createOffer(HOST));
  });

  it("allows the host's note on the offer", async () => {
    await seedListing();
    await assertSucceeds(createOffer(HOST, { hostNote: "The place is yours that week." }));
  });

  // The friends-only boundary from the host's side: a listing id isn't a capability.
  it("denies a host offering to someone outside the listing's ACL", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { guestUserID: STRANGER }));
  });

  // The hole the ACL check couldn't close: the host writes `allowedViewerIDs`, so they could add
  // a uid to their own listing then offer to it, landing an unsolicited stay in anyone's trip list.
  // The listing here names STRANGER in its ACL as that attack would; what they lack is a friend edge, now what's asked.
  it("denies a host offering to a non-friend they wrote into their own ACL", async () => {
    await seedListing({ allowedViewerIDs: [HOST, FRIEND, STRANGER] });
    await assertFails(createOffer(HOST, { guestUserID: STRANGER }));
  });

  // The mirror, so the case above can't pass by denying every stranger: same ACL, and only the accepted edge differs.
  it("allows the offer once that person is a real friend", async () => {
    await seedListing({ allowedViewerIDs: [HOST, FRIEND, STRANGER] });
    await seedFriendship(HOST, STRANGER);
    await assertSucceeds(createOffer(HOST, { guestUserID: STRANGER }));
  });

  it("denies an offer to a guest who has blocked the host", async () => {
    await seedListing();
    await seedBlock(FRIEND, HOST);
    await assertFails(createOffer(HOST));
  });

  it("denies an offer to a guest the host has blocked", async () => {
    await seedListing();
    await seedBlock(HOST, FRIEND);
    await assertFails(createOffer(HOST));
  });

  it("denies an offer for a listing the host does not own", async () => {
    await seedListing({ hostUserID: STRANGER, allowedViewerIDs: [STRANGER, HOST, FRIEND] });
    await assertFails(createOffer(HOST));
  });

  it("denies an offer on a deleted listing", async () => {
    await seedListing({ deletedAt: Timestamp.now() });
    await assertFails(createOffer(HOST));
  });

  it("denies an offer with check-out before check-in", async () => {
    await seedListing();
    await assertFails(
      createOffer(HOST, {
        checkIn: Timestamp.fromMillis(Date.now() + 4 * DAY_MS),
        checkOut: Timestamp.fromMillis(Date.now() + 2 * DAY_MS),
      })
    );
  });

  it("denies an offer for dates already past", async () => {
    await seedListing();
    await assertFails(
      createOffer(HOST, {
        checkIn: Timestamp.fromMillis(Date.now() - 10 * DAY_MS),
        checkOut: Timestamp.fromMillis(Date.now() - 8 * DAY_MS),
      })
    );
  });
});

describe("stayRequests/{id} create — forging the other side", () => {
  // The most important: a host writing status "pending" naming a friend as guest could accept it and count the stay toward their trust stats.
  it("denies a host manufacturing a pending request from a friend", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { status: "pending", initiatedBy: FRIEND }));
  });

  it("denies a host claiming the guest initiated their own offer", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { initiatedBy: FRIEND }));
  });

  // The mirror: a guest posting an "offered" document would fabricate an invitation.
  it("denies a guest creating an offered document", async () => {
    await seedListing();
    await assertFails(createOffer(FRIEND, { initiatedBy: FRIEND }));
  });

  it("denies a guest claiming the host offered", async () => {
    await seedListing();
    await assertFails(createOffer(FRIEND));
  });

  it("denies a stranger creating an offer between two other people", async () => {
    await seedListing();
    await assertFails(createOffer(STRANGER));
  });

  // The guest's words are theirs; a host writing a note, party size or arrival would put them in their friend's mouth.
  it("denies a host writing the guest's note on an offer", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { guestNote: "I'd love to come!" }));
  });

  it("denies a host writing the guest's party size on an offer", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { guestCount: 2 }));
  });

  it("denies a host writing the guest's arrival window on an offer", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { arrivalWindow: "morning" }));
  });

  // A guest's request is the host's to answer, so the host's note belongs on the reply.
  it("denies a guest writing the host's note on their own request", async () => {
    await seedListing();
    await assertFails(
      createOffer(FRIEND, { status: "pending", initiatedBy: FRIEND, hostNote: "Sure, come!" })
    );
  });

  it("denies an offer that is born accepted", async () => {
    await seedListing();
    await assertFails(createOffer(HOST, { status: "accepted" }));
  });
});

describe("stayRequests/{id} update — answering an offer", () => {
  const patch = (uid, data) => updateDoc(doc(as(uid), "stayRequests", OFFER), data);

  it("allows the guest to decline an offer", async () => {
    await seedListing();
    await seedOffer();
    await assertSucceeds(patch(FRIEND, { status: "declined", updatedAt: serverTimestamp() }));
  });

  it("allows the guest to decline with their own note", async () => {
    await seedListing();
    await seedOffer();
    await assertSucceeds(
      patch(FRIEND, { status: "declined", guestNote: "Away that week!", updatedAt: serverTimestamp() })
    );
  });

  // The offer's note is the host's words; a declining guest mustn't rewrite them.
  it("denies the guest overwriting the host's note while declining", async () => {
    await seedListing();
    await seedOffer({ hostNote: "The place is yours." });
    await assertFails(
      patch(FRIEND, { status: "declined", hostNote: "Never mind.", updatedAt: serverTimestamp() })
    );
  });

  // The callable isn't deployed, so the guest accepts from the client and the double-booking guard moved to the
  // host's reconciler. The deny cases that matter now live in accept.test.mjs.
  it("allows the guest to accept their offer directly", async () => {
    await seedListing();
    await seedOffer();
    await assertSucceeds(patch(FRIEND, { status: "accepted", updatedAt: serverTimestamp() }));
  });

  it("denies the host accepting their own offer on the guest's behalf", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(patch(HOST, { status: "accepted", updatedAt: serverTimestamp() }));
  });

  it("denies the host declining their own offer for the guest", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(patch(HOST, { status: "declined", updatedAt: serverTimestamp() }));
  });

  it("denies a stranger answering someone else's offer", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(patch(STRANGER, { status: "declined", updatedAt: serverTimestamp() }));
  });

  // Dates are what the guest agrees to; a host moving them afterwards could offer one week and book another.
  it("denies the host moving the dates on an offer", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(
      patch(HOST, {
        checkIn: Timestamp.fromMillis(Date.now() + 20 * DAY_MS),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies rewriting who started the offer", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(patch(HOST, { initiatedBy: FRIEND, updatedAt: serverTimestamp() }));
    await assertFails(patch(FRIEND, { initiatedBy: FRIEND, updatedAt: serverTimestamp() }));
  });
});

describe("stayRequests/{id} update — withdrawing an offer", () => {
  const patch = (uid, data) => updateDoc(doc(as(uid), "stayRequests", OFFER), data);

  // Cancelled, not declined: the friend never said no.
  it("allows the host to withdraw an unanswered offer", async () => {
    await seedListing();
    await seedOffer();
    await assertSucceeds(
      patch(HOST, { status: "cancelled", cancelledBy: HOST, updatedAt: serverTimestamp() })
    );
  });

  it("denies the host blaming the withdrawal on the guest", async () => {
    await seedListing();
    await seedOffer();
    await assertFails(
      patch(HOST, { status: "cancelled", cancelledBy: FRIEND, updatedAt: serverTimestamp() })
    );
  });

  it("denies withdrawing an offer that was already answered", async () => {
    await seedListing();
    await seedOffer("declined");
    await assertFails(
      patch(HOST, { status: "cancelled", cancelledBy: HOST, updatedAt: serverTimestamp() })
    );
  });
});

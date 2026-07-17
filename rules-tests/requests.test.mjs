// Stay requests and friend requests are the two writes that let one member land
// in another's inbox, so they are where the friends-only boundary and the block
// feature have to hold at the rules level, not just in the UI.
//
// Three boundaries are pinned here:
//   - a stay request requires the guest to be in the listing's read ACL, and no
//     block in either direction.
//   - the host may call off an accepted stay (cancelled), but a pending request
//     is declined, never host-cancelled.
//   - a friend request is refused when either party has blocked the other, and
//     the edge carries only its known keys.

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
const STAY = "stay-1";
const DAY_MS = 86_400_000;

let testEnv;

// An authenticated context defaults to sign_in_provider "custom", which is not
// "anonymous", so it clears the rules' isFullMember() gate.
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

/** Seeds documents the rules read but these tests aren't about. */
async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

/** A live listing hosted by HOST and shared with FRIEND. */
async function seedListing(extra = {}) {
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

async function seedStay(status) {
  await seed((db) =>
    setDoc(doc(db, "stayRequests", STAY), {
      id: STAY,
      listingID: LISTING,
      listingCity: "Town",
      listingHostName: "Host",
      hostUserID: HOST,
      guestUserID: FRIEND,
      checkIn: Timestamp.fromMillis(Date.now() + 5 * DAY_MS),
      checkOut: Timestamp.fromMillis(Date.now() + 8 * DAY_MS),
      status,
    })
  );
}

/** A stay request exactly as the client sends one. */
function requestBody(guest, overrides = {}) {
  return {
    id: "req-1",
    listingID: LISTING,
    listingCity: "Town",
    listingHostName: "Host",
    hostUserID: HOST,
    guestUserID: guest,
    checkIn: Timestamp.fromMillis(Date.now() + 2 * DAY_MS),
    checkOut: Timestamp.fromMillis(Date.now() + 4 * DAY_MS),
    status: "pending",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

const createRequest = (guest, overrides) =>
  setDoc(doc(as(guest), "stayRequests", "req-1"), requestBody(guest, overrides));

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-requests-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("stayRequests/{id} create — the friends-only boundary", () => {
  // The control: without it, a rule denying everything would pass the rest.
  it("allows a guest the listing is shared with", async () => {
    await seedListing();
    await assertSucceeds(createRequest(FRIEND));
  });

  it("denies a member outside the listing's ACL", async () => {
    await seedListing();
    await assertFails(createRequest(STRANGER));
  });

  it("denies a guest the host has blocked", async () => {
    await seedListing();
    await seedBlock(HOST, FRIEND);
    await assertFails(createRequest(FRIEND));
  });

  it("denies requesting a stay from a host you blocked", async () => {
    await seedListing();
    await seedBlock(FRIEND, HOST);
    await assertFails(createRequest(FRIEND));
  });

  it("denies a request that backdates its createdAt", async () => {
    await seedListing();
    await assertFails(
      createRequest(FRIEND, { createdAt: Timestamp.fromMillis(Date.now() - 30 * DAY_MS) })
    );
  });
});

describe("stayRequests/{id} update — host cancels an accepted stay", () => {
  it("allows the host to cancel an accepted stay, with a note", async () => {
    await seedStay("accepted");
    await assertSucceeds(
      updateDoc(doc(as(HOST), "stayRequests", STAY), {
        status: "cancelled",
        hostNote: "A pipe burst; I'm so sorry.",
        cancelledBy: HOST,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies the host cancelling a pending request (decline is the verb)", async () => {
    await seedStay("pending");
    await assertFails(
      updateDoc(doc(as(HOST), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: HOST,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies a host cancel that also rewrites the dates", async () => {
    await seedStay("accepted");
    await assertFails(
      updateDoc(doc(as(HOST), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: HOST,
        checkIn: Timestamp.fromMillis(Date.now() + 20 * DAY_MS),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("still allows the guest to cancel their accepted stay", async () => {
    await seedStay("accepted");
    await assertSucceeds(
      updateDoc(doc(as(FRIEND), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: FRIEND,
        updatedAt: serverTimestamp(),
      })
    );
  });
});

// `cancelledBy` is what tells the push trigger whom to notify, since both
// parties can cancel and the document is otherwise identical either way. It is
// therefore only worth anything if it cannot lie.
describe("stayRequests/{id} update — cancelledBy names whoever cancelled", () => {
  it("denies a host cancel that blames the guest", async () => {
    await seedStay("accepted");
    await assertFails(
      updateDoc(doc(as(HOST), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: FRIEND,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies a guest cancel that blames the host", async () => {
    await seedStay("accepted");
    await assertFails(
      updateDoc(doc(as(FRIEND), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: HOST,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies a cancel that omits cancelledBy", async () => {
    // Without it the trigger cannot tell who already knows, so it stays quiet —
    // making an unattributed cancellation a way to silence the notification.
    await seedStay("accepted");
    await assertFails(
      updateDoc(doc(as(FRIEND), "stayRequests", STAY), {
        status: "cancelled",
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies rewriting cancelledBy after the fact", async () => {
    await seedStay("accepted");
    await assertSucceeds(
      updateDoc(doc(as(FRIEND), "stayRequests", STAY), {
        status: "cancelled",
        cancelledBy: FRIEND,
        updatedAt: serverTimestamp(),
      })
    );
    // Terminal: no edits at all once cancelled.
    await assertFails(
      updateDoc(doc(as(FRIEND), "stayRequests", STAY), {
        cancelledBy: HOST,
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe("friendEdges/{id} create — blocks stop friend requests", () => {
  const [userA, userB] = [FRIEND, STRANGER].sort();
  const edgeID = `${userA}_${userB}`;

  const edgeBody = (initiator, extra = {}) => ({
    userA,
    userB,
    status: "pending",
    initiator,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...extra,
  });

  it("allows a friend request when neither party has blocked the other", async () => {
    await assertSucceeds(setDoc(doc(as(FRIEND), "friendEdges", edgeID), edgeBody(FRIEND)));
  });

  it("denies a friend request from someone the recipient blocked", async () => {
    await seedBlock(STRANGER, FRIEND);
    await assertFails(setDoc(doc(as(FRIEND), "friendEdges", edgeID), edgeBody(FRIEND)));
  });

  it("denies a friend request to someone the sender blocked", async () => {
    await seedBlock(FRIEND, STRANGER);
    await assertFails(setDoc(doc(as(FRIEND), "friendEdges", edgeID), edgeBody(FRIEND)));
  });

  it("denies an edge smuggling an unexpected key", async () => {
    await assertFails(
      setDoc(doc(as(FRIEND), "friendEdges", edgeID), edgeBody(FRIEND, { note: "hi" }))
    );
  });
});

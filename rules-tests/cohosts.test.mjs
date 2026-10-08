// Co-hosts are a delegation of authority over a listing, and the rules bound it. The
// interesting cases are what a co-host must *not* do while holding a credential that looks
// like the host's. Pinned boundaries:
//   - only the host changes the roster, and only to an accepted friend;
//   - a co-host can't promote themselves to host or add further co-hosts;
//   - a co-host can't rewrite `allowedViewerIDs` (it would republish the listing to their graph);
//   - a co-host can't delete the listing, by the delete rule or via `deletedAt` in an update;
//   - a co-host can read and write the private location and manual (a roommate who can't
//     see the door code can't let a guest in);
//   - a stranger can do none of it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { collection, deleteDoc, doc, getDoc, getDocs, orderBy, query, serverTimestamp, setDoc, updateDoc, where, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const COHOST = "user-cohost";
const FRIEND = "user-friend";
const STRANGER = "user-stranger";
const LISTING = "listing-1";

let testEnv;

const asHost = () => testEnv.authenticatedContext(HOST).firestore();
const asCoHost = () => testEnv.authenticatedContext(COHOST).firestore();
const asStranger = () => testEnv.authenticatedContext(STRANGER).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

async function seedFriendship(a, b, status = "accepted") {
  const [userA, userB] = [a, b].sort();
  await seed((db) =>
    setDoc(doc(db, "friendEdges", `${userA}_${userB}`), { userA, userB, status, initiator: userA })
  );
}

/** A valid listing document. `coHostUserIDs` defaults to empty, as at creation. */
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

/** Seeds a listing on which COHOST is already a co-host. */
async function seedCoHostedListing() {
  await seedListing({ coHostUserIDs: [COHOST] });
}

const listingDoc = (db) => doc(db, "homes", LISTING);
const locationDoc = (db) => doc(db, "homes", LISTING, "private", "location");
const manualDoc = (db) => doc(db, "homes", LISTING, "private", "manual");

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-cohost-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("homes/{id} — the co-host roster", () => {
  it("lets the host add an accepted friend as a co-host", async () => {
    await seedFriendship(HOST, COHOST);
    await seedListing();
    await assertSucceeds(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST] }));
  });

  // A co-host gets the street address, so "co-host" mustn't become a way to grant a stranger the front door.
  it("refuses a co-host who is not an accepted friend of the host", async () => {
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [STRANGER] }));
  });

  it("refuses a co-host whose friend request is still pending", async () => {
    await seedFriendship(HOST, COHOST, "pending");
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST] }));
  });

  // Rules can't loop, so the friend check holds only if additions arrive one at a time; a batch of two would pass the second unchecked.
  it("refuses two co-hosts added in a single write, even if both are friends", async () => {
    await seedFriendship(HOST, COHOST);
    await seedFriendship(HOST, FRIEND);
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST, FRIEND] }));
  });

  it("lets the host add friends one write at a time", async () => {
    await seedFriendship(HOST, COHOST);
    await seedFriendship(HOST, FRIEND);
    await seedListing();
    await assertSucceeds(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST] }));
    await assertSucceeds(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST, FRIEND] }));
  });

  // Taking a capability back is safe, so removal needs no friend edge (unfriending is when you'd remove them).
  it("lets the host remove a co-host even after the friendship is gone", async () => {
    await seedCoHostedListing();
    await assertSucceeds(updateDoc(listingDoc(asHost()), { coHostUserIDs: [] }));
  });

  it("refuses the host as their own co-host", async () => {
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [HOST] }));
  });

  it("refuses a roster longer than the cap", async () => {
    await seedListing();
    await assertFails(
      updateDoc(listingDoc(asHost()), { coHostUserIDs: ["a", "b", "c", "d", "e", "f"] })
    );
  });

  // Admitting a roster at create would need validating every name against the friend graph, which a loop-free rule can't do.
  //
  // `createdAt` must be serverTimestamp() (the create rule pins it to request.time), or the write
  // fails for an unrelated reason and the assertion passes vacuously; the sibling test proves this one tests what it claims.
  it("refuses a listing created with co-hosts already on it", async () => {
    await seedFriendship(HOST, COHOST);
    await assertFails(
      setDoc(
        doc(asHost(), "homes", "listing-2"),
        listingBody({ id: "listing-2", coHostUserIDs: [COHOST], createdAt: serverTimestamp() })
      )
    );
  });

  it("allows the otherwise-identical create with an empty roster", async () => {
    await assertSucceeds(
      setDoc(
        doc(asHost(), "homes", "listing-2"),
        listingBody({ id: "listing-2", coHostUserIDs: [], createdAt: serverTimestamp() })
      )
    );
  });

  it("refuses a stranger adding themselves to the roster", async () => {
    await seedFriendship(HOST, STRANGER);
    await seedListing();
    await assertFails(updateDoc(listingDoc(asStranger()), { coHostUserIDs: [STRANGER] }));
  });
});

describe("homes/{id} — what a co-host may write", () => {
  it("lets a co-host edit the description of the home", async () => {
    await seedCoHostedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        description: "Now with a futon.",
        sleeping: { numGuestRooms: 1, arrangements: { bed: 1, futon: 1 } },
      })
    );
  });

  // The merged field on the public document: a co-host's blocking goes to `private/availability`
  // (availability.test.mjs), but the published union is theirs to rewrite since their save round-trips it.
  it("lets a co-host write the merged availability field", async () => {
    await seedCoHostedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        unavailableDateRanges: [{ start: Timestamp.now(), end: Timestamp.now() }],
      })
    );
  });

  // The listing's identity: a co-host who could write this would own the listing.
  it("refuses a co-host promoting themselves to host", async () => {
    await seedCoHostedListing();
    await assertFails(updateDoc(listingDoc(asCoHost()), { hostUserID: COHOST }));
  });

  it("refuses a co-host adding further co-hosts", async () => {
    await seedFriendship(HOST, FRIEND);
    await seedCoHostedListing();
    await assertFails(updateDoc(listingDoc(asCoHost()), { coHostUserIDs: [COHOST, FRIEND] }));
  });

  it("refuses a co-host removing the host's other co-hosts", async () => {
    await seedListing({ coHostUserIDs: [COHOST, FRIEND] });
    await assertFails(updateDoc(listingDoc(asCoHost()), { coHostUserIDs: [COHOST] }));
  });

  // The client rebuilds allowedViewerIDs from the saving user's friends; a co-host writing it would republish a friends-only listing to another graph.
  it("refuses a co-host rewriting the read ACL", async () => {
    await seedCoHostedListing();
    await assertFails(
      updateDoc(listingDoc(asCoHost()), { allowedViewerIDs: [HOST, COHOST, STRANGER] })
    );
  });

  it("refuses a co-host rewriting the host's name or contact details", async () => {
    await seedCoHostedListing();
    await assertFails(updateDoc(listingDoc(asCoHost()), { hostName: "Impostor" }));
    await assertFails(updateDoc(listingDoc(asCoHost()), { hostContactInfo: "me@evil.test" }));
  });

  it("refuses a co-host deleting the listing", async () => {
    await seedCoHostedListing();
    await assertFails(deleteDoc(listingDoc(asCoHost())));
  });

  // Refused the delete rule, a co-host mustn't reach the same end through the update rule (`deletedAt` is what the feed filters on).
  it("refuses a co-host soft-deleting the listing through an update", async () => {
    await seedCoHostedListing();
    await assertFails(updateDoc(listingDoc(asCoHost()), { deletedAt: Timestamp.now() }));
  });

  it("still lets the host do all of it", async () => {
    await seedCoHostedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asHost()), { allowedViewerIDs: [HOST, COHOST, FRIEND] })
    );
    await assertSucceeds(updateDoc(listingDoc(asHost()), { hostName: "Host Renamed" }));
    await assertSucceeds(deleteDoc(listingDoc(asHost())));
  });

  it("refuses a stranger editing a listing they do not manage", async () => {
    await seedCoHostedListing();
    await assertFails(updateDoc(listingDoc(asStranger()), { description: "mine now" }));
  });
});

describe("homes/{id} — reading a co-hosted listing", () => {
  it("lets a co-host read the listing they manage", async () => {
    await seedCoHostedListing();
    await assertSucceeds(getDoc(listingDoc(asCoHost())));
  });

  // The roster is the grant: losing the friendship (and the ACL place) mustn't lock a co-host out; removing them from the roster is how the host takes it back.
  it("lets a co-host read a friends-only listing they have dropped out of the ACL of", async () => {
    await seedListing({ coHostUserIDs: [COHOST], allowedViewerIDs: [HOST] });
    await assertSucceeds(getDoc(listingDoc(asCoHost())));
  });

  it("still hides a friends-only listing from a stranger", async () => {
    await seedCoHostedListing();
    await assertFails(getDoc(listingDoc(asStranger())));
  });
});

describe("homes/{id}/private — the address and the house manual", () => {
  const location = { street: "123 Oak St", latitude: 45.5, longitude: -122.6 };
  const manual = { checkInInstructions: "Lockbox by the gate.", wifiPassword: "hunter2" };

  it("lets a co-host read and write the street address", async () => {
    await seedCoHostedListing();
    await seed((db) => setDoc(locationDoc(db), location));
    await assertSucceeds(getDoc(locationDoc(asCoHost())));
    await assertSucceeds(setDoc(locationDoc(asCoHost()), { ...location, street: "125 Oak St" }));
  });

  it("lets a co-host read and write the house manual", async () => {
    await seedCoHostedListing();
    await assertSucceeds(setDoc(manualDoc(asCoHost()), manual));
    await assertSucceeds(getDoc(manualDoc(asCoHost())));
  });

  it("hides the street address from a stranger", async () => {
    await seedCoHostedListing();
    await seed((db) => setDoc(locationDoc(db), location));
    await assertFails(getDoc(locationDoc(asStranger())));
    await assertFails(setDoc(locationDoc(asStranger()), location));
  });

  // Removal is a real revocation, not just a UI change.
  it("locks a removed co-host out of the address again", async () => {
    await seedListing({ coHostUserIDs: [] });
    await seed((db) => setDoc(locationDoc(db), location));
    await assertFails(getDoc(locationDoc(asCoHost())));
  });
});

// A co-host answers stay requests for the listings they manage. The boundaries now separate
// "acts with the host's authority" from "is the host": a co-host answers requests but can't
// rename the host, offer the place, or answer a request they themselves sent.
describe("stayRequests — the co-host's half of the inbox", () => {
  const REQUEST = "request-1";
  const asGuest = () => testEnv.authenticatedContext(FRIEND).firestore();
  const requestDoc = (db, id = REQUEST) => doc(db, "stayRequests", id);

  function requestBody(extra = {}) {
    return {
      id: REQUEST,
      listingID: LISTING,
      listingCity: "Portland",
      hostUserID: HOST,
      guestUserID: FRIEND,
      checkIn: Timestamp.fromMillis(Date.now() + 86400000),
      checkOut: Timestamp.fromMillis(Date.now() + 3 * 86400000),
      status: "pending",
      createdAt: Timestamp.now(),
      ...extra,
    };
  }

  async function seedRequest(extra = {}) {
    await seedCoHostedListing();
    await seed((db) => setDoc(requestDoc(db), requestBody(extra)));
  }

  it("lets a co-host read a request for the listing they manage", async () => {
    await seedRequest();
    await assertSucceeds(getDoc(requestDoc(asCoHost())));
  });

  // The app reads requests through snapshot queries, not getDoc, and a query is evaluated against the read
  // rule differently. Adding `isListingManager()` (a get()) risked denying the whole query, including the
  // host's own inbox. These pin that the queries the app runs still resolve.
  it("lets the host list their incoming requests by hostUserID", async () => {
    await seedRequest();
    const q = query(
      collection(asHost(), "stayRequests"),
      where("hostUserID", "==", HOST),
      orderBy("createdAt", "desc")
    );
    await assertSucceeds(getDocs(q));
  });

  it("lets a co-host list a listing's requests by listingID", async () => {
    await seedRequest();
    const q = query(
      collection(asCoHost(), "stayRequests"),
      where("listingID", "in", [LISTING]),
      orderBy("createdAt", "desc")
    );
    await assertSucceeds(getDocs(q));
  });

  it("still refuses a stranger listing a listing's requests", async () => {
    await seedRequest();
    const q = query(
      collection(asStranger(), "stayRequests"),
      where("listingID", "in", [LISTING]),
      orderBy("createdAt", "desc")
    );
    await assertFails(getDocs(q));
  });

  it("still hides that request from a stranger", async () => {
    await seedRequest();
    await assertFails(getDoc(requestDoc(asStranger())));
  });

  it("lets a co-host decline a pending request", async () => {
    await seedRequest();
    await assertSucceeds(updateDoc(requestDoc(asCoHost()), {
      status: "declined",
      hostNote: "Sorry, we're full that week.",
      updatedAt: serverTimestamp(),
    }));
  });

  it("refuses a stranger declining it", async () => {
    await seedRequest();
    await assertFails(updateDoc(requestDoc(asStranger()), {
      status: "declined",
      updatedAt: serverTimestamp(),
    }));
  });

  it("lets a co-host cancel an accepted stay", async () => {
    await seedRequest({ status: "accepted" });
    await assertSucceeds(updateDoc(requestDoc(asCoHost()), {
      status: "cancelled",
      cancelledBy: HOST,
      updatedAt: serverTimestamp(),
    }));
  });

  // `cancelledBy` names the side, not the individual: the push trigger branches on it and the guest's trip row reads it.
  it("refuses a co-host stamping cancelledBy with their own id", async () => {
    await seedRequest({ status: "accepted" });
    await assertFails(updateDoc(requestDoc(asCoHost()), {
      status: "cancelled",
      cancelledBy: COHOST,
      updatedAt: serverTimestamp(),
    }));
  });

  // Acceptance was the callable's alone; the callable isn't deployed, so the host side accepts
  // from the client and a co-host is the host side (accept.test.mjs covers the path and address
  // grant). What survives is the co-host part: they may answer a request that was made, not
  // manufacture one. Accepting an offer is still the guest's, and the callable's.
  it("refuses a co-host accepting an offer on the guest's behalf", async () => {
    await seedRequest({ status: "offered" });
    await assertFails(updateDoc(requestDoc(asCoHost()), {
      status: "accepted",
      updatedAt: serverTimestamp(),
    }));
  });

  // The name is the host's own; a co-host's rename would rewrite trip rows to something the host never chose.
  it("refuses a co-host rewriting the denormalized host name", async () => {
    await seedRequest();
    await assertFails(updateDoc(requestDoc(asCoHost()), { listingHostName: "Not The Host" }));
  });

  // Offering is the host's: the create rule pins hostUserID to the caller, so a co-host can't mint one.
  it("refuses a co-host offering the place to a friend", async () => {
    await seedCoHostedListing();
    await seedFriendship(COHOST, FRIEND);
    await assertFails(setDoc(requestDoc(asCoHost(), "request-offer"), requestBody({
      id: "request-offer",
      status: "offered",
      initiatedBy: COHOST,
      createdAt: serverTimestamp(),
    })));
  });

  // A co-host may also ask to stay at a listing they manage, putting them on both sides; they may send it, and the callable refuses to let them answer it.
  it("lets a co-host decline a request from someone else, not their own", async () => {
    await seedCoHostedListing();
    await seed((db) => setDoc(requestDoc(db, "request-own"), requestBody({
      id: "request-own",
      guestUserID: COHOST,
    })));
    // Declining their own request is indistinguishable from cancelling it, which they may do as the guest.
    await assertSucceeds(updateDoc(requestDoc(asCoHost(), "request-own"), {
      status: "declined",
      updatedAt: serverTimestamp(),
    }));
  });

  it("still lets the host do all of it", async () => {
    await seedRequest();
    await assertSucceeds(getDoc(requestDoc(asHost())));
    await assertSucceeds(updateDoc(requestDoc(asHost()), {
      status: "declined",
      updatedAt: serverTimestamp(),
    }));
  });

  it("still lets the guest read their own request", async () => {
    await seedRequest();
    await assertSucceeds(getDoc(requestDoc(asGuest())));
  });

  // Removal revokes this the same way it revokes the address.
  it("locks a removed co-host out of the inbox again", async () => {
    await seedListing({ coHostUserIDs: [] });
    await seed((db) => setDoc(requestDoc(db), requestBody()));
    await assertFails(getDoc(requestDoc(asCoHost())));
    await assertFails(updateDoc(requestDoc(asCoHost()), {
      status: "declined",
      updatedAt: serverTimestamp(),
    }));
  });
});

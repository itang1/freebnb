// Co-hosts (feature 14) are a delegation of authority over a listing, and the
// rules are where that delegation is bounded. The interesting cases are not
// "can a co-host edit the listing" — they are all the things a co-host must
// *not* be able to do while holding a credential that looks a lot like the
// host's.
//
// Six boundaries are pinned here:
//   - only the host changes the roster, and only to an accepted friend;
//   - a co-host cannot promote themselves to host, nor add further co-hosts;
//   - a co-host cannot rewrite `allowedViewerIDs` (which would republish a
//     friends-only listing to their own social graph);
//   - a co-host cannot delete the listing, by the delete rule or by smuggling
//     `deletedAt` through the update rule;
//   - a co-host *can* read and write the private location and house manual,
//     because a roommate who can't see the door code can't let a guest in;
//   - a stranger can do none of it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, serverTimestamp, setDoc, updateDoc, Timestamp } from "firebase/firestore";

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

  // A co-host is handed the street address. "Co-host" must not become a way to
  // grant a stranger read access to the host's front door.
  it("refuses a co-host who is not an accepted friend of the host", async () => {
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [STRANGER] }));
  });

  it("refuses a co-host whose friend request is still pending", async () => {
    await seedFriendship(HOST, COHOST, "pending");
    await seedListing();
    await assertFails(updateDoc(listingDoc(asHost()), { coHostUserIDs: [COHOST] }));
  });

  // Rules cannot loop, so the friend check only holds if additions arrive one at
  // a time. A batch of two would let the second one through unchecked.
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

  // Taking a capability back is always safe, so removal needs no friend edge —
  // which matters, because unfriending someone is exactly when you'd remove them.
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

  // Admitting a roster at create would mean validating every name in it against
  // the friend graph, which a loop-free rule cannot do.
  //
  // `createdAt` must be serverTimestamp(): the create rule pins it to
  // request.time, so any other value fails the write for a reason that has
  // nothing to do with co-hosts, and the assertion would pass vacuously. The
  // sibling test below is what proves this one is testing what it claims.
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

  // The merged field on the public document. A co-host's own blocking now goes
  // to `private/availability` (availability.test.mjs covers that); what this
  // asserts is that the published union is theirs to rewrite, because their save
  // round-trips it.
  it("lets a co-host write the merged availability field", async () => {
    await seedCoHostedListing();
    await assertSucceeds(
      updateDoc(listingDoc(asCoHost()), {
        unavailableDateRanges: [{ start: Timestamp.now(), end: Timestamp.now() }],
      })
    );
  });

  // The listing's identity. A co-host who could write this would own the listing.
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

  // The client rebuilds allowedViewerIDs from the *saving* user's friends. If a
  // co-host could write it, saving an edit would silently republish a
  // friends-only listing to a social graph the host never saw.
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

  // Refused the delete rule, a co-host must not reach the same end through the
  // update rule: `deletedAt` is what the feed filters on.
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

  // The roster is the grant. Losing the friendship, and so a place in
  // allowedViewerIDs, must not lock a co-host out of the listing they manage;
  // removing them from the roster is how the host takes it back.
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

// A co-host answers stay requests for the listings they manage. This was the
// one piece of the delegation that was withheld, which left a co-host able to
// block dates on a calendar while blind to the bookings filling it. The
// boundaries that matter now are the ones separating "acts with the host's
// authority" from "is the host": a co-host answers requests, and still cannot
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

  // `cancelledBy` names the side, not the individual: the push trigger branches
  // on it and the guest's trip row reads it back.
  it("refuses a co-host stamping cancelledBy with their own id", async () => {
    await seedRequest({ status: "accepted" });
    await assertFails(updateDoc(requestDoc(asCoHost()), {
      status: "cancelled",
      cancelledBy: COHOST,
      updatedAt: serverTimestamp(),
    }));
  });

  // Acceptance used to be the callable's alone, and this asserted that a co-host
  // could not write the status directly. The callable is not deployed, so the
  // host side now accepts from the client and a co-host is the host side —
  // accept.test.mjs covers that path and the address grant that rides with it.
  //
  // What survives from the old assertion is the part that was really about
  // co-hosts rather than about acceptance: a co-host may answer a request that
  // was made, and may not manufacture one. Accepting an *offer* is still the
  // guest's, and still the callable's.
  it("refuses a co-host accepting an offer on the guest's behalf", async () => {
    await seedRequest({ status: "offered" });
    await assertFails(updateDoc(requestDoc(asCoHost()), {
      status: "accepted",
      updatedAt: serverTimestamp(),
    }));
  });

  // The name is the host's own, and a rename propagating from a co-host would
  // rewrite trip rows to say something the host never chose.
  it("refuses a co-host rewriting the denormalized host name", async () => {
    await seedRequest();
    await assertFails(updateDoc(requestDoc(asCoHost()), { listingHostName: "Not The Host" }));
  });

  // Offering is the host's to extend: the create rule pins hostUserID to the
  // caller, so a co-host cannot mint one even for the listing they manage.
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

  // The listing a co-host manages is one they may also ask to stay at, which
  // puts them on both sides of the document. They may send it; the callable is
  // what refuses to let them answer it (see acceptStayRequest).
  it("lets a co-host decline a request from someone else, not their own", async () => {
    await seedCoHostedListing();
    await seed((db) => setDoc(requestDoc(db, "request-own"), requestBody({
      id: "request-own",
      guestUserID: COHOST,
    })));
    // Declining their own request is indistinguishable from cancelling it, which
    // they may already do as the guest, so the rule need not single it out.
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

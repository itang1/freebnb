// Circles: friend-grouped booking rules.
//
// The client hides what a policy forbids, but hiding is not refusing, and the
// caller a host restricting someone has in mind is exactly the one running a
// modified client. So the whole feature has to hold here, at the rules, with the
// UI switched off.
//
// What is pinned:
//   - the resolution chain (override > circle > Default) picks the same policy
//     the Swift resolver does, and always terminates;
//   - a host with no circles restricts nothing, which is what they had before;
//   - each of the three policy fields actually refuses a write;
//   - an absent arrivalWindow is read as 'flexible' rather than as unchecked;
//   - the frequency cap cannot be dodged by declining to advance the counter,
//     by sliding the counter's window, or by spending someone else's;
//   - moving the dates on a pending request re-checks the notice rule;
//   - a guest cannot read the circles or the memberships, only the policy
//     resolved for them;
//   - Default cannot be deleted, and no other circle can claim to be it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
  Timestamp,
} from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const FRIEND = "user-friend";
const OTHER = "user-other";
const LISTING = "listing-1";
const DAY_MS = 86_400_000;
// Reused verbatim wherever a test both seeds a counter and writes it again: the
// rules pin windowStart across an increment, so two Timestamps a millisecond
// apart are two different windows.
const OPEN_WINDOW_START = Timestamp.fromMillis(Date.now() - DAY_MS);
const ELAPSED_WINDOW_START = Timestamp.fromMillis(Date.now() - 31 * DAY_MS);

const ALL_ARRIVALS = ["flexible", "morning", "afternoon", "evening", "lateNight"];

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

async function seedListing() {
  await seed((db) =>
    setDoc(doc(db, "homes", LISTING), {
      hostUserID: HOST,
      hostName: "Host",
      address: { city: "Town", state: "CA" },
      sleeping: { numGuestRooms: 1 },
      guestPolicy: { maxGuests: 2, maxStayDays: 7 },
      amenities: {},
      allowedViewerIDs: [HOST, FRIEND, OTHER],
    })
  );
}

const policy = (overrides = {}) => ({
  allowedArrivalOptions: ALL_ARRIVALS,
  minNoticeHours: 0,
  maxStaysPerPeriod: null,
  ...overrides,
});

/** Writes a circle straight in, bypassing rules — these tests are about reads. */
async function seedCircle(circleID, circlePolicy, extra = {}) {
  await seed((db) =>
    setDoc(doc(db, "users", HOST, "circles", circleID), {
      name: circleID === "default" ? "Everyone else" : "Close friend",
      isDefault: circleID === "default",
      sortOrder: 0,
      policy: circlePolicy,
      ...extra,
    })
  );
}

async function seedMembership(friendID, membership) {
  await seed((db) =>
    setDoc(doc(db, "users", HOST, "circleMembers", friendID), membership)
  );
}

async function seedCounter(guestID, { windowStart, count }) {
  await seed((db) =>
    setDoc(doc(db, "stayCounters", `${HOST}_${guestID}`), {
      hostUserID: HOST,
      guestUserID: guestID,
      windowStart,
      count,
    })
  );
}

function requestBody(guest, overrides = {}) {
  return {
    id: "req-1",
    listingID: LISTING,
    listingCity: "Town",
    listingHostName: "Host",
    hostUserID: HOST,
    guestUserID: guest,
    checkIn: Timestamp.fromMillis(Date.now() + 10 * DAY_MS),
    checkOut: Timestamp.fromMillis(Date.now() + 12 * DAY_MS),
    status: "pending",
    arrivalWindow: "evening",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

/** The same body with a key left off entirely — `undefined` is not writable. */
function requestWithout(guest, key, overrides = {}) {
  const body = requestBody(guest, overrides);
  delete body[key];
  return body;
}

const createRequest = (guest, overrides, requestID = "req-1") =>
  setDoc(doc(as(guest), "stayRequests", requestID), requestBody(guest, overrides));

/**
 * A request and its counter advance in one commit, which is the only way a
 * capped policy admits one — `stayCounterAdvanced()` reads the post-commit
 * counter, so a separate write would be a request with no slot behind it.
 */
function createRequestWithCounter(guest, { count, windowStart }, overrides = {}, requestID = "req-1") {
  const db = as(guest);
  const batch = writeBatch(db);
  batch.set(doc(db, "stayRequests", requestID), requestBody(guest, overrides));
  batch.set(doc(db, "stayCounters", `${HOST}_${guest}`), {
    hostUserID: HOST,
    guestUserID: guest,
    windowStart: windowStart ?? serverTimestamp(),
    count,
  });
  return batch.commit();
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-circles-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedListing();
});

// ---------------------------------------------------------------------------

describe("circle documents", () => {
  it("lets the host create a circle with a valid policy", async () => {
    await assertSucceeds(
      setDoc(doc(as(HOST), "users", HOST, "circles", "c1"), {
        name: "Close friend",
        isDefault: false,
        sortOrder: 1,
        policy: policy({ minNoticeHours: 48 }),
      })
    );
  });

  it("refuses a circle claiming to be the Default one from another id", async () => {
    await assertFails(
      setDoc(doc(as(HOST), "users", HOST, "circles", "c1"), {
        name: "Impostor",
        isDefault: true,
        sortOrder: 1,
        policy: policy(),
      })
    );
  });

  it("refuses the Default circle disclaiming the role its id gives it", async () => {
    await assertFails(
      setDoc(doc(as(HOST), "users", HOST, "circles", "default"), {
        name: "Everyone else",
        isDefault: false,
        sortOrder: 0,
        policy: policy(),
      })
    );
  });

  it("refuses a policy with no arrival options at all", async () => {
    await assertFails(
      setDoc(doc(as(HOST), "users", HOST, "circles", "c1"), {
        name: "Nobody",
        isDefault: false,
        sortOrder: 1,
        policy: policy({ allowedArrivalOptions: [] }),
      })
    );
  });

  it("refuses an arrival option that is not one of the five", async () => {
    await assertFails(
      setDoc(doc(as(HOST), "users", HOST, "circles", "c1"), {
        name: "Odd",
        isDefault: false,
        sortOrder: 1,
        policy: policy({ allowedArrivalOptions: ["dawn"] }),
      })
    );
  });

  it("lets the host rename and reconfigure Default like any other circle", async () => {
    await seedCircle("default", policy());
    await assertSucceeds(
      setDoc(doc(as(HOST), "users", HOST, "circles", "default"), {
        name: "The rest of you",
        isDefault: true,
        sortOrder: 0,
        policy: policy({ minNoticeHours: 72, maxStaysPerPeriod: { count: 1, periodDays: 90 } }),
      })
    );
  });

  it("refuses to delete Default, and allows deleting any other circle", async () => {
    await seedCircle("default", policy());
    await seedCircle("c1", policy());
    await assertFails(deleteDoc(doc(as(HOST), "users", HOST, "circles", "default")));
    await assertSucceeds(deleteDoc(doc(as(HOST), "users", HOST, "circles", "c1")));
  });

  it("keeps circles and memberships away from the friend they are about", async () => {
    await seedCircle("c1", policy());
    await seedMembership(FRIEND, { circleID: "c1" });
    await assertFails(getDoc(doc(as(FRIEND), "users", HOST, "circles", "c1")));
    await assertFails(getDoc(doc(as(FRIEND), "users", HOST, "circleMembers", FRIEND)));
  });

  it("lets a guest read the policy resolved for them, and nobody else's", async () => {
    await seed((db) => setDoc(doc(db, "users", HOST, "bookingPolicies", FRIEND), policy()));
    await seed((db) => setDoc(doc(db, "users", HOST, "bookingPolicies", OTHER), policy()));
    await assertSucceeds(getDoc(doc(as(FRIEND), "users", HOST, "bookingPolicies", FRIEND)));
    await assertFails(getDoc(doc(as(FRIEND), "users", HOST, "bookingPolicies", OTHER)));
  });

  it("refuses a guest writing their own projected policy", async () => {
    await assertFails(
      setDoc(doc(as(FRIEND), "users", HOST, "bookingPolicies", FRIEND), policy())
    );
  });
});

// ---------------------------------------------------------------------------

describe("arrival options", () => {
  it("allows a host with no circles at all — nothing configured, nothing restricted", async () => {
    await assertSucceeds(createRequest(FRIEND, { arrivalWindow: "lateNight" }));
  });

  it("refuses an arrival time the friend's circle withholds", async () => {
    await seedCircle("default", policy());
    await seedCircle("c1", policy({ allowedArrivalOptions: ["morning", "afternoon"] }));
    await seedMembership(FRIEND, { circleID: "c1" });
    await assertFails(createRequest(FRIEND, { arrivalWindow: "lateNight" }));
    await assertSucceeds(createRequest(FRIEND, { arrivalWindow: "morning" }));
  });

  it("reads an omitted arrivalWindow as 'flexible' rather than as unchecked", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["morning"] }));
    await assertFails(
      setDoc(doc(as(FRIEND), "stayRequests", "req-1"), requestWithout(FRIEND, "arrivalWindow"))
    );
  });

  it("falls back to Default for a friend with no membership document", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["morning"] }));
    await assertFails(createRequest(FRIEND, { arrivalWindow: "evening" }));
    await assertSucceeds(createRequest(FRIEND, { arrivalWindow: "morning" }));
  });

  it("falls back to Default when the membership names a circle that is gone", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["morning"] }));
    await seedMembership(FRIEND, { circleID: "deleted-circle" });
    await assertFails(createRequest(FRIEND, { arrivalWindow: "evening" }));
  });

  it("lets a per-friend override supersede the circle, in both directions", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["morning"] }));
    await seedCircle("c1", policy({ allowedArrivalOptions: ["morning"] }));
    await seedMembership(FRIEND, {
      circleID: "c1",
      overridePolicy: policy({ allowedArrivalOptions: ["lateNight"] }),
    });
    await assertSucceeds(createRequest(FRIEND, { arrivalWindow: "lateNight" }));
    await assertFails(createRequest(FRIEND, { arrivalWindow: "morning" }, "req-2"));
  });

  it("restricts one friend without touching another", async () => {
    await seedCircle("default", policy());
    await seedCircle("c1", policy({ allowedArrivalOptions: ["morning"] }));
    await seedMembership(FRIEND, { circleID: "c1" });
    await assertFails(createRequest(FRIEND, { arrivalWindow: "lateNight" }));
    await assertSucceeds(createRequest(OTHER, { arrivalWindow: "lateNight" }, "req-2"));
  });
});

// ---------------------------------------------------------------------------

describe("minimum notice", () => {
  it("refuses a check-in inside the notice window and allows one outside it", async () => {
    await seedCircle("default", policy({ minNoticeHours: 72 }));
    await assertFails(
      createRequest(FRIEND, { checkIn: Timestamp.fromMillis(Date.now() + 2 * DAY_MS) })
    );
    await assertSucceeds(
      createRequest(FRIEND, { checkIn: Timestamp.fromMillis(Date.now() + 4 * DAY_MS) })
    );
  });

  // "No minimum" has to mean exactly the behaviour a host had before Circles,
  // and checkIn is a local start-of-day — so a literal `checkIn >= request.time`
  // would quietly withdraw the same-day request the app has always allowed.
  // Zero is skipped rather than compared against, on both sides.
  it("still admits a same-day request when the notice is zero", async () => {
    await seedCircle("default", policy({ minNoticeHours: 0 }));
    await assertSucceeds(
      createRequest(FRIEND, {
        checkIn: Timestamp.fromMillis(Date.now() - 6 * 3_600_000),
        checkOut: Timestamp.fromMillis(Date.now() + 2 * DAY_MS),
      })
    );
  });

  it("re-checks the notice window when a pending request moves its dates", async () => {
    await seedCircle("default", policy({ minNoticeHours: 72 }));
    await assertSucceeds(createRequest(FRIEND));
    // The dodge this closes: ask for a date far out, then walk it back in.
    await assertFails(
      updateDoc(doc(as(FRIEND), "stayRequests", "req-1"), {
        checkIn: Timestamp.fromMillis(Date.now() + 1 * DAY_MS),
        checkOut: Timestamp.fromMillis(Date.now() + 3 * DAY_MS),
        updatedAt: serverTimestamp(),
      })
    );
    await assertSucceeds(
      updateDoc(doc(as(FRIEND), "stayRequests", "req-1"), {
        checkIn: Timestamp.fromMillis(Date.now() + 5 * DAY_MS),
        checkOut: Timestamp.fromMillis(Date.now() + 7 * DAY_MS),
        updatedAt: serverTimestamp(),
      })
    );
  });
});

// ---------------------------------------------------------------------------

describe("frequency cap", () => {
  const capped = () => policy({ maxStaysPerPeriod: { count: 2, periodDays: 30 } });

  it("refuses a capped request that does not advance the counter", async () => {
    await seedCircle("default", capped());
    await assertFails(createRequest(FRIEND));
  });

  it("allows the first request when it opens a window in the same commit", async () => {
    await seedCircle("default", capped());
    await assertSucceeds(createRequestWithCounter(FRIEND, { count: 1 }));
  });

  it("allows a second request inside the window and refuses the third", async () => {
    await seedCircle("default", capped());
    await seedCounter(FRIEND, { windowStart: OPEN_WINDOW_START, count: 1 });
    await assertSucceeds(
      createRequestWithCounter(FRIEND, { count: 2, windowStart: OPEN_WINDOW_START }, {}, "req-2")
    );
    await seedCounter(FRIEND, { windowStart: OPEN_WINDOW_START, count: 2 });
    await assertFails(
      createRequestWithCounter(FRIEND, { count: 3, windowStart: OPEN_WINDOW_START }, {}, "req-3")
    );
  });

  it("refuses sliding the window forward to buy headroom", async () => {
    await seedCircle("default", capped());
    await seedCounter(FRIEND, { windowStart: OPEN_WINDOW_START, count: 2 });
    // Reopening a window that has not elapsed is the whole dodge.
    await assertFails(createRequestWithCounter(FRIEND, { count: 1 }, {}, "req-4"));
  });

  it("reopens the window once the period has actually elapsed", async () => {
    await seedCircle("default", capped());
    await seedCounter(FRIEND, { windowStart: ELAPSED_WINDOW_START, count: 2 });
    await assertSucceeds(createRequestWithCounter(FRIEND, { count: 1 }, {}, "req-5"));
  });

  it("refuses a guest spending another guest's counter", async () => {
    await seedCircle("default", capped());
    const db = as(OTHER);
    const batch = writeBatch(db);
    batch.set(doc(db, "stayRequests", "req-6"), requestBody(OTHER));
    batch.set(doc(db, "stayCounters", `${HOST}_${FRIEND}`), {
      hostUserID: HOST,
      guestUserID: FRIEND,
      windowStart: serverTimestamp(),
      count: 1,
    });
    await assertFails(batch.commit());
  });

  it("asks for no counter at all when the policy is uncapped", async () => {
    await seedCircle("default", policy({ minNoticeHours: 24 }));
    await assertSucceeds(createRequest(FRIEND));
  });
});

// ---------------------------------------------------------------------------

// The rules engine allows 1000 expressions per evaluation, and the first draft
// of the resolution above spent them all on an ordinary booking by re-reading
// the same documents from four helpers. These two drive the longest chain there
// is — membership, override, all three fields set, counter advanced — and they
// assert *success*, which is the only assertion that can tell "the policy
// permitted this" from "the engine gave up". An assertFails would pass either
// way, which is exactly how the bug hid.
describe("the longest resolution chain still evaluates", () => {
  const everything = () =>
    policy({
      allowedArrivalOptions: ["morning", "evening"],
      minNoticeHours: 48,
      maxStaysPerPeriod: { count: 2, periodDays: 30 },
    });

  it("admits a booking that satisfies an override with every field set", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["flexible"] }));
    await seedCircle("c1", policy({ allowedArrivalOptions: ["flexible"] }));
    await seedMembership(FRIEND, { circleID: "c1", overridePolicy: everything() });
    await assertSucceeds(createRequestWithCounter(FRIEND, { count: 1 }));
  });

  it("admits a date change under an override with every field set", async () => {
    await seedCircle("default", policy({ allowedArrivalOptions: ["flexible"] }));
    await seedCircle("c1", policy({ allowedArrivalOptions: ["flexible"] }));
    await seedMembership(FRIEND, { circleID: "c1", overridePolicy: everything() });
    await assertSucceeds(createRequestWithCounter(FRIEND, { count: 1 }));
    await assertSucceeds(
      updateDoc(doc(as(FRIEND), "stayRequests", "req-1"), {
        checkIn: Timestamp.fromMillis(Date.now() + 20 * DAY_MS),
        checkOut: Timestamp.fromMillis(Date.now() + 22 * DAY_MS),
        updatedAt: serverTimestamp(),
      })
    );
  });
});

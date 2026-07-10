// The trust-and-safety rules are the ones a modified client has the most to
// gain from breaking: reputation is what a stranger decides to sleep in a house
// on, and `reports` is where the evidence against them lives.
//
// Four boundaries are pinned here:
//   - trustStats is server-owned: a host cannot award themselves a rating.
//   - a review requires a *completed* stay you were *on*, about the *other* party.
//   - a reference requires an accepted friend edge.
//   - reports are readable and triageable only by an `admin` custom claim.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, setDoc, updateDoc, serverTimestamp, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const HOST = "user-host";
const GUEST = "user-guest";
const STRANGER = "user-stranger";
const STAY = "stay-1";
const LISTING = "listing-1";

let testEnv;

const asHost = () => testEnv.authenticatedContext(HOST).firestore();
const asGuest = () => testEnv.authenticatedContext(GUEST).firestore();
const asStranger = () => testEnv.authenticatedContext(STRANGER).firestore();
const asAdmin = () => testEnv.authenticatedContext("user-mod", { admin: true }).firestore();

/** Seeds documents the rules read but these tests aren't about. */
async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

async function seedStay(status) {
  await seed((db) =>
    setDoc(doc(db, "stayRequests", STAY), {
      id: STAY,
      listingID: LISTING,
      listingCity: "Town",
      listingHostName: "Host",
      hostUserID: HOST,
      guestUserID: GUEST,
      checkIn: Timestamp.fromMillis(Date.now() - 3 * 86_400_000),
      checkOut: Timestamp.fromMillis(Date.now() - 86_400_000),
      status,
    })
  );
}

async function seedUser(userID, extra = {}) {
  await seed((db) =>
    setDoc(doc(db, "users", userID), {
      displayName: "Someone",
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      ...extra,
    })
  );
}

async function seedFriendship(a, b, status) {
  const [userA, userB] = [a, b].sort();
  await seed((db) =>
    setDoc(doc(db, "friendEdges", `${userA}_${userB}`), {
      userA,
      userB,
      status,
      initiator: userA,
    })
  );
}

/** The review `author` would legitimately write about `subject` for the seeded stay. */
function reviewBody(author, subject, role) {
  return {
    id: `${STAY}_${author}`,
    stayRequestID: STAY,
    listingID: LISTING,
    authorUserID: author,
    subjectUserID: subject,
    role,
    rating: 5,
    publicComment: "Lovely.",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

const writeReview = (db, author, subject, role, id = `${STAY}_${author}`) =>
  setDoc(doc(db, "reviews", id), reviewBody(author, subject, role));

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-trust-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

describe("users/{id}.trustStats — server-owned reputation", () => {
  it("denies a user awarding themselves stats on create", async () => {
    await assertFails(
      setDoc(doc(asHost(), "users", HOST), {
        displayName: "Host",
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        trustStats: { staysHosted: 99, averageRating: 5, idVerified: true },
      })
    );
  });

  it("denies a user editing stats the server wrote", async () => {
    await seedUser(HOST, { trustStats: { staysHosted: 1, idVerified: false } });
    await assertFails(
      setDoc(doc(asHost(), "users", HOST), {
        displayName: "Host",
        createdAt: Timestamp.now(),
        updatedAt: serverTimestamp(),
        trustStats: { staysHosted: 99, idVerified: true },
      })
    );
  });

  // The control: a rename must still work while stats are carried through intact.
  // Without it, a rule that denied every update would pass both cases above.
  it("allows a rename that leaves stats untouched", async () => {
    const stats = { staysHosted: 1, idVerified: false };
    // `createdAt` is immutable, so the rewrite has to carry the exact value the
    // document already holds — hence a fixed timestamp rather than a sentinel.
    const createdAt = Timestamp.fromMillis(1_700_000_000_000);
    await seed((db) =>
      setDoc(doc(db, "users", HOST), {
        displayName: "Host",
        createdAt,
        updatedAt: createdAt,
        trustStats: stats,
      })
    );
    await assertSucceeds(
      setDoc(doc(asHost(), "users", HOST), {
        displayName: "Renamed",
        createdAt,
        updatedAt: serverTimestamp(),
        trustStats: stats,
      })
    );
  });
});

describe("stayRequests/{id} — completion", () => {
  it("allows either party to complete an accepted stay that has begun", async () => {
    await seedStay("accepted");
    await assertSucceeds(
      updateDoc(doc(asGuest(), "stayRequests", STAY), {
        status: "completed",
        completedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies a stranger completing someone else's stay", async () => {
    await seedStay("accepted");
    await assertFails(
      updateDoc(doc(asStranger(), "stayRequests", STAY), {
        status: "completed",
        completedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies completing a stay that hasn't started", async () => {
    // The guard against a host farming completed stays off future bookings.
    await seed((db) =>
      setDoc(doc(db, "stayRequests", STAY), {
        id: STAY,
        listingID: LISTING,
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: HOST,
        guestUserID: GUEST,
        checkIn: Timestamp.fromMillis(Date.now() + 7 * 86_400_000),
        checkOut: Timestamp.fromMillis(Date.now() + 9 * 86_400_000),
        status: "accepted",
      })
    );
    await assertFails(
      updateDoc(doc(asHost(), "stayRequests", STAY), {
        status: "completed",
        completedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies reviving a completed stay", async () => {
    await seedStay("completed");
    await assertFails(
      updateDoc(doc(asGuest(), "stayRequests", STAY), {
        status: "cancelled",
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe("reviews/{id}", () => {
  it("allows each party to review the other after completion", async () => {
    await seedStay("completed");
    await assertSucceeds(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost"));
    await assertSucceeds(writeReview(asHost(), HOST, GUEST, "hostReviewingGuest"));
  });

  it("denies a review of a stay that hasn't completed", async () => {
    await seedStay("accepted");
    await assertFails(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost"));
  });

  it("denies a review by someone who wasn't on the stay", async () => {
    await seedStay("completed");
    await assertFails(writeReview(asStranger(), STRANGER, HOST, "guestReviewingHost"));
  });

  it("denies a review whose role contradicts which side you were on", async () => {
    await seedStay("completed");
    await assertFails(writeReview(asGuest(), GUEST, HOST, "hostReviewingGuest"));
  });

  it("denies reviewing yourself", async () => {
    await seedStay("completed");
    await assertFails(writeReview(asGuest(), GUEST, GUEST, "guestReviewingHost"));
  });

  it("denies a document id that doesn't pin one review per stay and author", async () => {
    // Without this, a guest could write ten reviews of one stay under ten ids.
    await seedStay("completed");
    await assertFails(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost", `${STAY}_extra`));
  });

  it("denies rewriting someone else's review", async () => {
    await seedStay("completed");
    await assertSucceeds(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost"));
    await assertFails(
      updateDoc(doc(asHost(), "reviews", `${STAY}_${GUEST}`), {
        rating: 1,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("allows the author to revise their own review", async () => {
    await seedStay("completed");
    await assertSucceeds(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost"));
    await assertSucceeds(
      updateDoc(doc(asGuest(), "reviews", `${STAY}_${GUEST}`), {
        rating: 3,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("keeps private feedback readable only by its author and its subject", async () => {
    await seedStay("completed");
    await assertSucceeds(writeReview(asGuest(), GUEST, HOST, "guestReviewingHost"));
    const path = `reviews/${STAY}_${GUEST}/private/feedback`;

    await assertSucceeds(setDoc(doc(asGuest(), path), { text: "The shower was cold." }));
    await assertSucceeds(getDoc(doc(asHost(), path)));
    await assertFails(getDoc(doc(asStranger(), path)));
    // Only the reviewer writes it; the reviewed doesn't get to edit what was said.
    await assertFails(setDoc(doc(asHost(), path), { text: "It was warm." }));
  });
});

describe("references/{id}", () => {
  const referenceID = `${HOST}_${GUEST}`;
  const body = () => ({
    id: referenceID,
    authorUserID: GUEST,
    subjectUserID: HOST,
    text: "I've known them for years.",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  });

  it("allows an accepted friend to vouch", async () => {
    await seedFriendship(GUEST, HOST, "accepted");
    await assertSucceeds(setDoc(doc(asGuest(), "references", referenceID), body()));
  });

  it("denies a stranger vouching", async () => {
    await assertFails(setDoc(doc(asGuest(), "references", referenceID), body()));
  });

  it("denies a merely pending friend vouching", async () => {
    await seedFriendship(GUEST, HOST, "pending");
    await assertFails(setDoc(doc(asGuest(), "references", referenceID), body()));
  });

  it("lets the subject remove a reference from their own profile", async () => {
    await seedFriendship(GUEST, HOST, "accepted");
    await assertSucceeds(setDoc(doc(asGuest(), "references", referenceID), body()));
    await assertSucceeds(deleteDoc(doc(asHost(), "references", referenceID)));
  });
});

describe("reports/{id} — the moderation inbox", () => {
  const report = () => ({
    reporterUserID: GUEST,
    targetType: "listing",
    targetID: LISTING,
    reason: "Asked me to wire a deposit.",
    status: "new",
    source: "user",
    createdAt: serverTimestamp(),
  });

  it("lets a member file a report they cannot read back", async () => {
    await assertSucceeds(setDoc(doc(asGuest(), "reports", "r1"), report()));
    await assertFails(getDoc(doc(asGuest(), "reports", "r1")));
  });

  it("denies filing a report that pre-declares its own triage state", async () => {
    await assertFails(
      setDoc(doc(asGuest(), "reports", "r2"), { ...report(), status: "dismissed" })
    );
  });

  it("denies impersonating the auto-moderation triggers", async () => {
    await assertFails(setDoc(doc(asGuest(), "reports", "r3"), { ...report(), source: "auto" }));
  });

  it("lets a moderator read and triage", async () => {
    await seed((db) => setDoc(doc(db, "reports", "r4"), { ...report(), createdAt: Timestamp.now() }));
    await assertSucceeds(getDoc(doc(asAdmin(), "reports", "r4")));
    await assertSucceeds(
      updateDoc(doc(asAdmin(), "reports", "r4"), {
        status: "actioned",
        moderatorNote: "Delisted.",
        reviewedBy: "user-mod",
        reviewedAt: serverTimestamp(),
      })
    );
  });

  it("denies a moderator rewriting the evidence", async () => {
    await seed((db) => setDoc(doc(db, "reports", "r5"), { ...report(), createdAt: Timestamp.now() }));
    await assertFails(
      updateDoc(doc(asAdmin(), "reports", "r5"), { status: "dismissed", reason: "Nothing here." })
    );
  });

  it("denies a non-moderator triaging", async () => {
    await seed((db) => setDoc(doc(db, "reports", "r6"), { ...report(), createdAt: Timestamp.now() }));
    await assertFails(updateDoc(doc(asStranger(), "reports", "r6"), { status: "dismissed" }));
  });
});

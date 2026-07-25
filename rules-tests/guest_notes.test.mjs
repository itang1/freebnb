// A guest's private notes on the hosts they stay with and the listings they
// consider — the symmetric twin of friend_notes.test.mjs, from the other side of
// the same stay.
//
// The UI never shows a note to anyone but its author, but the caller this
// feature has to hold against is precisely the host who has stopped using the
// UI: a technical user reading raw documents, listing the collection, or
// guessing a note id. So the whole promise has to be true here, at the rules,
// with the app switched off.
//
// What is pinned:
//   - the host a note is about cannot read it, by get or by list, ever;
//   - neither can a stranger, an anonymous caller, or the guest is not exposed
//     to a moderator (there is no isAdmin() branch on this collection);
//   - a guest cannot write a note into somebody else's collection, and cannot
//     write a `host` note about themselves;
//   - an edit cannot re-point a note at a different host or listing, cannot
//     switch a note's kind between host and listing, or rewrite when it was
//     written;
//   - the shape holds: known subject types only, no extra fields, no empty or
//     over-long text, no non-string stay link;
//   - a note about a former host stays readable and deletable by its author;
//   - the prompt marker carries a timestamp and nothing else, and is just as
//     unreadable to the host.

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
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
} from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const GUEST = "user-guest";
const HOST = "user-host";
const OTHER = "user-other";
const LISTING = "home-1";
const NOTE = "note-1";
const STAY = "stay-1";

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const anon = () => testEnv.unauthenticatedContext().firestore();

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

const noteBody = (overrides = {}) => ({
  subjectType: "host",
  subjectID: HOST,
  text: "Warm host, but the heating never worked.",
  ...overrides,
});

/** Writes a note straight in, bypassing rules — most of these are about reads. */
async function seedNote(id = NOTE, overrides = {}) {
  await seed((db) =>
    setDoc(doc(db, "users", GUEST, "guestNotes", id), {
      ...noteBody(overrides),
      createdAt: new Date("2026-03-01T12:00:00Z"),
      updatedAt: new Date("2026-03-01T12:00:00Z"),
    })
  );
}

const notesOf = (db, guestID) => collection(db, "users", guestID, "guestNotes");
const noteDoc = (db, guestID = GUEST, id = NOTE) => doc(db, "users", guestID, "guestNotes", id);

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-guest-notes-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

// ---------------------------------------------------------------------------

describe("who can read a note", () => {
  beforeEach(() => seedNote());

  it("lets the author read their own note", async () => {
    await assertSucceeds(getDoc(noteDoc(as(GUEST))));
  });

  it("lets the author list their own notes", async () => {
    await assertSucceeds(getDocs(notesOf(as(GUEST), GUEST)));
  });

  // The whole feature in one assertion. The host knows the guest's uid (it is on
  // every stay request between them) and can guess a document path; the rule,
  // not the absence of a screen, is what stops them.
  it("refuses the host the note is about", async () => {
    await assertFails(getDoc(noteDoc(as(HOST))));
  });

  it("refuses the host a listing of the collection", async () => {
    await assertFails(getDocs(notesOf(as(HOST), GUEST)));
  });

  it("refuses an unrelated signed-in user", async () => {
    await assertFails(getDoc(noteDoc(as(OTHER))));
  });

  it("refuses an anonymous caller", async () => {
    await assertFails(getDoc(noteDoc(anon())));
  });

  // Being on the other side of the stay a note names buys nothing: the note is
  // the guest's, not the stay's.
  it("refuses the host of the stay the note is filed under", async () => {
    await seedNote("note-2", { stayRequestID: STAY });
    await assertFails(getDoc(noteDoc(as(HOST), GUEST, "note-2")));
  });

  // Notes outlive the stay. A guest who never returns still keeps the note that
  // explains why.
  it("still lets the author read a note about a host they never see again", async () => {
    await assertSucceeds(getDoc(noteDoc(as(GUEST))));
    await assertSucceeds(deleteDoc(noteDoc(as(GUEST))));
  });
});

describe("writing a note", () => {
  it("lets a guest write a note about a host", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody(),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("lets a guest write a note about a listing", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ subjectType: "listing", subjectID: LISTING }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("lets a guest attach a stay for context", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ subjectType: "listing", subjectID: LISTING, stayRequestID: STAY }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // Nullable means nullable: a note tied to no stay is the ordinary case, not a
  // degraded one.
  it("lets a guest write a note tied to no stay at all", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ stayRequestID: null }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a note written into someone else's collection", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST), GUEST), {
        ...noteBody({ subjectID: OTHER }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // A `host` note about yourself would put guest-authored text on the one
  // profile you might later hand somebody else to look at.
  it("refuses a host note about yourself", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ subjectType: "host", subjectID: GUEST }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses an unknown subject type", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ subjectType: "moderator" }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a missing subject id", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        subjectType: "host",
        text: "No subject id",
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses empty text", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ text: "" }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses text past the cap", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ text: "x".repeat(2001) }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("accepts text exactly at the cap", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ text: "x".repeat(2000) }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a non-string stay link", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ stayRequestID: 7 }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // A field nobody validates is a field somebody will eventually put a rating
  // in, or a report flag — the two things this feature exists instead of.
  it("refuses an unknown field", async () => {
    await assertFails(
      setDoc(noteDoc(as(GUEST)), {
        ...noteBody({ rating: 2 }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe("editing and deleting", () => {
  beforeEach(() => seedNote());

  it("lets the author revise the text", async () => {
    await assertSucceeds(
      updateDoc(noteDoc(as(GUEST)), {
        text: "Actually the heating was fine once I found the switch.",
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("lets the author attach and clear a stay link", async () => {
    await assertSucceeds(
      updateDoc(noteDoc(as(GUEST)), { stayRequestID: STAY, updatedAt: serverTimestamp() })
    );
    await assertSucceeds(
      updateDoc(noteDoc(as(GUEST)), { stayRequestID: null, updatedAt: serverTimestamp() })
    );
  });

  // A note re-filed under somebody else keeps its date and reads as
  // contemporaneous evidence about a host it was never written about.
  it("refuses re-pointing a note at a different host", async () => {
    await assertFails(
      updateDoc(noteDoc(as(GUEST)), { subjectID: OTHER, updatedAt: serverTimestamp() })
    );
  });

  // A host note quietly reborn as a listing note (or the reverse) is the same
  // re-filing dressed differently; the kind is pinned too.
  it("refuses switching a note's kind between host and listing", async () => {
    await assertFails(
      updateDoc(noteDoc(as(GUEST)), {
        subjectType: "listing",
        subjectID: LISTING,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses rewriting when the note was written", async () => {
    await assertFails(
      updateDoc(noteDoc(as(GUEST)), {
        createdAt: new Date("2026-07-01T12:00:00Z"),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses an edit by the host the note is about", async () => {
    await assertFails(updateDoc(noteDoc(as(HOST), GUEST), { text: "Actually I was a great host" }));
  });

  it("lets the author delete their note", async () => {
    await assertSucceeds(deleteDoc(noteDoc(as(GUEST))));
  });

  // The subject cannot suppress what is said about them any more than they can
  // read it. Both are the same rule.
  it("refuses a delete by the host the note is about", async () => {
    await assertFails(deleteDoc(noteDoc(as(HOST), GUEST)));
  });

  it("refuses a delete by a stranger", async () => {
    await assertFails(deleteDoc(noteDoc(as(OTHER), GUEST)));
  });
});

describe("post-trip prompt markers", () => {
  const promptDoc = (db, guestID = GUEST) =>
    doc(db, "users", guestID, "guestNotePrompts", STAY);

  it("lets the guest record that they were asked", async () => {
    await assertSucceeds(setDoc(promptDoc(as(GUEST)), { dismissedAt: serverTimestamp() }));
  });

  // The marker says a prompt was seen. It must never grow a field saying what
  // the guest thought.
  it("refuses any field other than the timestamp", async () => {
    await assertFails(
      setDoc(promptDoc(as(GUEST)), { dismissedAt: serverTimestamp(), verdict: "bad host" })
    );
  });

  it("refuses a marker written by anyone else", async () => {
    await assertFails(setDoc(promptDoc(as(HOST)), { dismissedAt: serverTimestamp() }));
  });

  // Even "the guest was prompted about this trip" is the guest's business.
  it("refuses the host a read of the marker", async () => {
    await seed((db) =>
      setDoc(doc(db, "users", GUEST, "guestNotePrompts", STAY), { dismissedAt: new Date() })
    );
    await assertFails(getDoc(promptDoc(as(HOST))));
  });
});

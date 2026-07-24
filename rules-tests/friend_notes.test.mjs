// A host's private notes on their friends.
//
// The UI never shows a note to anyone but its author, but the caller this
// feature has to hold against is precisely the friend who has stopped using the
// UI: a technical guest reading raw documents, listing the collection, or
// guessing a note id. So the whole promise has to be true here, at the rules,
// with the app switched off.
//
// What is pinned:
//   - the subject of a note cannot read it, by get or by list, ever;
//   - neither can a stranger, an anonymous caller, or the other party to the
//     stay the note names;
//   - a host cannot write a note into somebody else's collection, and cannot
//     write one about themselves;
//   - an edit cannot re-point a note at a different person, or rewrite when it
//     was written;
//   - the shape holds: no extra fields, no empty or over-long text, no
//     non-string stay link;
//   - a note about a former friend stays readable and deletable by its author,
//     because the note explaining why you unfriended somebody is the one you
//     most need to keep;
//   - the prompt marker carries a timestamp and nothing else, and is just as
//     unreadable to the friend.

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

const HOST = "user-host";
const FRIEND = "user-friend";
const OTHER = "user-other";
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
  subjectUserID: FRIEND,
  text: "Left the place spotless. Would host again.",
  ...overrides,
});

/** Writes a note straight in, bypassing rules — most of these are about reads. */
async function seedNote(id = NOTE, overrides = {}) {
  await seed((db) =>
    setDoc(doc(db, "users", HOST, "friendNotes", id), {
      ...noteBody(overrides),
      createdAt: new Date("2026-03-01T12:00:00Z"),
      updatedAt: new Date("2026-03-01T12:00:00Z"),
    })
  );
}

const notesOf = (db, hostID) => collection(db, "users", hostID, "friendNotes");
const noteDoc = (db, hostID = HOST, id = NOTE) => doc(db, "users", hostID, "friendNotes", id);

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-friend-notes-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(() => testEnv.cleanup());

beforeEach(() => testEnv.clearFirestore());

// ---------------------------------------------------------------------------

describe("who can read a note", () => {
  beforeEach(() => seedNote());

  it("lets the author read their own note", async () => {
    await assertSucceeds(getDoc(noteDoc(as(HOST))));
  });

  it("lets the author list their own notes", async () => {
    await assertSucceeds(getDocs(notesOf(as(HOST), HOST)));
  });

  // The whole feature in one assertion. The friend knows the host's uid (it is
  // on every listing they can see) and can guess a document path; the rule, not
  // the absence of a screen, is what stops them.
  it("refuses the friend the note is about", async () => {
    await assertFails(getDoc(noteDoc(as(FRIEND))));
  });

  it("refuses the friend a listing of the collection", async () => {
    await assertFails(getDocs(notesOf(as(FRIEND), HOST)));
  });

  it("refuses an unrelated signed-in user", async () => {
    await assertFails(getDoc(noteDoc(as(OTHER))));
  });

  it("refuses an anonymous caller", async () => {
    await assertFails(getDoc(noteDoc(anon())));
  });

  // Being on the other side of the stay a note names buys nothing: the note is
  // the host's, not the stay's.
  it("refuses the guest of the stay the note is filed under", async () => {
    await seedNote("note-2", { stayRequestID: STAY });
    await assertFails(getDoc(noteDoc(as(FRIEND), HOST, "note-2")));
  });

  // Notes outlive the friendship. Deleting the edge must not lock a host out of
  // the note that explains why they deleted it.
  it("still lets the author read a note about someone no longer a friend", async () => {
    await assertSucceeds(getDoc(noteDoc(as(HOST))));
    await assertSucceeds(deleteDoc(noteDoc(as(HOST))));
  });
});

describe("writing a note", () => {
  it("lets a host write a note about a friend", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody(),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("lets a host attach a stay for context", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ stayRequestID: STAY }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // Nullable means nullable: a general note tied to no visit is the ordinary
  // case, not a degraded one.
  it("lets a host write a note tied to no stay at all", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ stayRequestID: null }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a note written into someone else's collection", async () => {
    await assertFails(
      setDoc(noteDoc(as(FRIEND), HOST), {
        ...noteBody({ subjectUserID: OTHER }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a note about yourself", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ subjectUserID: HOST }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses empty text", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ text: "" }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses text past the cap", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ text: "x".repeat(2001) }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("accepts text exactly at the cap", async () => {
    await assertSucceeds(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ text: "x".repeat(2000) }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a non-string stay link", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ stayRequestID: 7 }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // A field nobody validates is a field somebody will eventually put a rating
  // in, which is the thing this feature exists instead of.
  it("refuses an unknown field", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        ...noteBody({ rating: 2 }),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses a note missing its subject", async () => {
    await assertFails(
      setDoc(noteDoc(as(HOST)), {
        text: "No subject",
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
      updateDoc(noteDoc(as(HOST)), {
        text: "Actually, the kitchen was a state.",
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("lets the author attach and clear a stay link", async () => {
    await assertSucceeds(
      updateDoc(noteDoc(as(HOST)), { stayRequestID: STAY, updatedAt: serverTimestamp() })
    );
    await assertSucceeds(
      updateDoc(noteDoc(as(HOST)), { stayRequestID: null, updatedAt: serverTimestamp() })
    );
  });

  // A note re-filed under somebody else keeps its date and reads as
  // contemporaneous evidence about a person it was never written about.
  it("refuses re-pointing a note at a different person", async () => {
    await assertFails(
      updateDoc(noteDoc(as(HOST)), { subjectUserID: OTHER, updatedAt: serverTimestamp() })
    );
  });

  it("refuses rewriting when the note was written", async () => {
    await assertFails(
      updateDoc(noteDoc(as(HOST)), {
        createdAt: new Date("2026-07-01T12:00:00Z"),
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("refuses an edit by the friend the note is about", async () => {
    await assertFails(updateDoc(noteDoc(as(FRIEND), HOST), { text: "Actually I was great" }));
  });

  it("lets the author delete their note", async () => {
    await assertSucceeds(deleteDoc(noteDoc(as(HOST))));
  });

  // The subject cannot suppress what is said about them any more than they can
  // read it. Both are the same rule.
  it("refuses a delete by the friend the note is about", async () => {
    await assertFails(deleteDoc(noteDoc(as(FRIEND), HOST)));
  });

  it("refuses a delete by a stranger", async () => {
    await assertFails(deleteDoc(noteDoc(as(OTHER), HOST)));
  });
});

describe("post-stay prompt markers", () => {
  const promptDoc = (db, hostID = HOST) =>
    doc(db, "users", hostID, "friendNotePrompts", STAY);

  it("lets the host record that they were asked", async () => {
    await assertSucceeds(setDoc(promptDoc(as(HOST)), { dismissedAt: serverTimestamp() }));
  });

  // The marker says a prompt was seen. It must never grow a field saying what
  // the host thought.
  it("refuses any field other than the timestamp", async () => {
    await assertFails(
      setDoc(promptDoc(as(HOST)), { dismissedAt: serverTimestamp(), verdict: "bad guest" })
    );
  });

  it("refuses a marker written by anyone else", async () => {
    await assertFails(setDoc(promptDoc(as(FRIEND)), { dismissedAt: serverTimestamp() }));
  });

  // Even "the host was prompted about this stay" is the host's business.
  it("refuses the friend a read of the marker", async () => {
    await seed((db) => setDoc(doc(db, "users", HOST, "friendNotePrompts", STAY), { dismissedAt: new Date() }));
    await assertFails(getDoc(promptDoc(as(FRIEND))));
  });
});

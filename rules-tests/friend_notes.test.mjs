// A host's private notes on their friends. The UI shows a note only to its author, but the
// caller to hold against is the friend who stopped using the UI and reads raw documents, lists
// the collection or guesses a note id. Pinned:
//   - the subject can't read it, by get or list;
//   - neither can a stranger, an anonymous caller or the other party to the stay named;
//   - a host can't write into someone else's collection or a note about themselves;
//   - an edit can't re-point a note or rewrite its date;
//   - the shape holds: no extra fields, no empty/over-long text or non-string stay link;
//   - a note about a former friend stays readable and deletable (the note explaining an unfriending is the one to keep);
//   - the prompt marker is a timestamp only, and as unreadable to the friend.

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

  // The whole feature in one assertion: the friend knows the host's uid and can guess a path; the rule, not a missing screen, stops them.
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

  // The other side of the stay buys nothing: the note is the host's, not the stay's.
  it("refuses the guest of the stay the note is filed under", async () => {
    await seedNote("note-2", { stayRequestID: STAY });
    await assertFails(getDoc(noteDoc(as(FRIEND), HOST, "note-2")));
  });

  // Notes outlive the friendship; deleting the edge mustn't lock a host out of the note explaining it.
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

  // Nullable means nullable: a general note tied to no visit is ordinary.
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

  // A field nobody validates will eventually hold a rating, which this feature exists instead of.
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

  // A re-filed note keeps its date and reads as contemporaneous evidence about someone it was never written about.
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

  // The subject can't suppress what's said about them any more than read it.
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

  // The marker says a prompt was seen; it must never grow a field saying what the host thought.
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

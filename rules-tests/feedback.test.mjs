// In-app feedback notes (feature 43) are a one-way drop box: a signed-in full
// member can post a categorized note about themselves, and only a moderator can
// ever read the queue. The boundaries pinned here mirror the `reports` shape:
//   - a full member posts a valid note but cannot read it back;
//   - the note must be about the poster (userID == uid), a known category, and
//     within the length cap;
//   - an anonymous guest cannot post (isFullMember gate);
//   - a note cannot pre-declare a triage status other than "new", nor smuggle
//     extra keys;
//   - only a moderator reads; nobody updates or deletes.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp, Timestamp } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const USER = "user-1";
const OTHER = "user-2";

let testEnv;

// Defaults to sign_in_provider "custom", a full member.
const asUser = () => testEnv.authenticatedContext(USER).firestore();
const asOther = () => testEnv.authenticatedContext(OTHER).firestore();
const asAdmin = () => testEnv.authenticatedContext("user-mod", { admin: true }).firestore();
// Overriding the whole `firebase` claim flips this context to anonymous, which
// the rules' isFullMember() gate must reject.
const asGuest = () =>
  testEnv
    .authenticatedContext(USER, { firebase: { sign_in_provider: "anonymous", identities: {} } })
    .firestore();

function note(extra = {}) {
  return {
    userID: USER,
    category: "idea",
    message: "It would be great to sort saved listings by distance.",
    appVersion: "1.2",
    status: "new",
    createdAt: serverTimestamp(),
    ...extra,
  };
}

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await writer(context.firestore());
  });
}

describe("feedback/{id} — the feedback drop box", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  beforeEach(() => testEnv.clearFirestore());

  it("lets a member post a note they cannot read back", async () => {
    await assertSucceeds(setDoc(doc(asUser(), "feedback", "f1"), note()));
    await assertFails(getDoc(doc(asUser(), "feedback", "f1")));
  });

  it("allows a note with the optional appVersion omitted", async () => {
    const { appVersion, ...rest } = note();
    await assertSucceeds(setDoc(doc(asUser(), "feedback", "f2"), rest));
  });

  it("allows every declared category", async () => {
    for (const category of ["idea", "problem", "praise"]) {
      await assertSucceeds(setDoc(doc(asUser(), "feedback", `cat-${category}`), note({ category })));
    }
  });

  it("denies posting on behalf of another user", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f3"), note({ userID: OTHER })));
  });

  it("denies an anonymous guest", async () => {
    await assertFails(setDoc(doc(asGuest(), "feedback", "f4"), note()));
  });

  it("denies an unknown category", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f5"), note({ category: "spam" })));
  });

  it("denies an empty message", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f6"), note({ message: "" })));
  });

  it("denies a message over the 2000-char cap", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f7"), note({ message: "x".repeat(2001) })));
  });

  it("denies pre-declaring a triage status other than new", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f8"), note({ status: "actioned" })));
  });

  it("denies smuggling an extra key", async () => {
    await assertFails(setDoc(doc(asUser(), "feedback", "f9"), note({ moderatorNote: "hi" })));
  });

  it("lets a moderator read the queue", async () => {
    await seed((db) => setDoc(doc(db, "feedback", "f10"), note({ createdAt: Timestamp.now() })));
    await assertSucceeds(getDoc(doc(asAdmin(), "feedback", "f10")));
  });

  it("denies a non-moderator reading the queue", async () => {
    await seed((db) => setDoc(doc(db, "feedback", "f11"), note({ createdAt: Timestamp.now() })));
    await assertFails(getDoc(doc(asOther(), "feedback", "f11")));
  });

  it("denies updating or deleting, even by a moderator", async () => {
    await seed((db) => setDoc(doc(db, "feedback", "f12"), note({ createdAt: Timestamp.now() })));
    await assertFails(updateDoc(doc(asAdmin(), "feedback", "f12"), { status: "actioned" }));
    await assertFails(deleteDoc(doc(asAdmin(), "feedback", "f12")));
  });
});

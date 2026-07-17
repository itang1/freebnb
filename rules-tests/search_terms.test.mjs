// The `searchTerms` index on the public user doc (R1). Friend search queries
// this array, so the rules have to admit an honest one and bound a dishonest
// one. Rules cannot loop, so the individual prefixes are unverifiable; what is
// pinned here is the perimeter that *is* checkable — the size cap, the
// whole-name requirement, and that nothing else sneaks into the document.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, serverTimestamp, setDoc, Timestamp } from "firebase/firestore";

// The same builder the client, the seed, and the backfill use.
const require = createRequire(import.meta.url);
const { searchTerms } = require("../scripts/search_terms.js");

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

const ME = "user-me";
const NAME = "SpongeBob SquarePants";

let testEnv;

const asMe = () => testEnv.authenticatedContext(ME).firestore();
const myDoc = (db) => doc(db, "users", ME);

/** A valid public profile, with whatever the caller wants overridden. */
function profileBody(extra = {}) {
  return {
    displayName: NAME,
    searchTerms: searchTerms(NAME),
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...extra,
  };
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-search-terms-rules-tests",
    firestore: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

describe("users/{uid}.searchTerms", () => {
  it("accepts the terms the shared builder produces", async () => {
    await assertSucceeds(setDoc(myDoc(asMe()), profileBody()));
  });

  // The backfill exists precisely because these documents are out there. If the
  // rules stopped admitting them, every legacy profile would be frozen out of
  // its own updates.
  it("still accepts a profile with no searchTerms at all", async () => {
    await assertSucceeds(
      setDoc(myDoc(asMe()), { displayName: NAME, createdAt: serverTimestamp(), updatedAt: serverTimestamp() })
    );
  });

  it("rejects terms that omit the name they claim to index", async () => {
    // The one dishonesty that is catchable: terms that don't carry the
    // lowercased displayName. Without this, a profile could index itself under
    // any words at all while showing an unrelated name.
    await assertFails(setDoc(myDoc(asMe()), profileBody({ searchTerms: ["spongebob", "squarepants"] })));
  });

  it("rejects a name change that leaves the old terms behind", async () => {
    await assertSucceeds(setDoc(myDoc(asMe()), profileBody()));
    // createdAt is immutable on update, so a rename sends only what changes —
    // exactly what UserProfileRepository.updateDisplayName writes.
    const rename = (extra) =>
      setDoc(myDoc(asMe()), { displayName: "Patrick Star", updatedAt: serverTimestamp(), ...extra }, { merge: true });

    // Renaming without reindexing would keep the user findable under the old
    // name — the client rebuilds the array on every rename for this reason.
    await assertFails(rename({}));
    await assertSucceeds(rename({ searchTerms: searchTerms("Patrick Star") }));
  });

  it("rejects an oversized term list", async () => {
    const stuffed = [NAME.toLowerCase(), ...Array.from({ length: 60 }, (_, i) => `term${i}`)];
    await assertFails(setDoc(myDoc(asMe()), profileBody({ searchTerms: stuffed })));
  });

  it("rejects a non-list in the field", async () => {
    await assertFails(setDoc(myDoc(asMe()), profileBody({ searchTerms: NAME.toLowerCase() })));
  });

  it("is readable by another full member, which is what makes search work", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), "users", ME), {
        displayName: NAME,
        searchTerms: searchTerms(NAME),
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      });
    });
    const other = testEnv.authenticatedContext("user-other").firestore();
    await assertSucceeds(getDoc(doc(other, "users", ME)));
  });
});

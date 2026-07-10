// Blocking is a rules boundary, not a UI one. The app hides a blocked thread,
// but nothing stops a modified client from writing to `messages` directly, so
// the rule is the only real control.
//
// The case that matters most here is the S11 regression: `recipientHasBlocked`
// checked one direction only, so the *blocker* could keep writing messages to
// the person they had blocked. `blockedEitherWay` closes it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, serverTimestamp, setDoc, writeBatch } from "firebase/firestore";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

// Sorted, as the rules require: participants is always [smaller, larger].
const SENDER = "user-aaaa";
const RECIPIENT = "user-bbbb";
const PARTICIPANTS = [SENDER, RECIPIENT].sort();

let testEnv;

// A message write must carry the sender's rate-limit counter in the same commit,
// because the create rule gates on `rateCounterAdvanced`. This mirrors the
// transaction FirestoreMessagesRepository.send commits, so a rules change that
// breaks the real client breaks these tests too.
function sendMessage(db, senderUserID, messageID) {
  const batch = writeBatch(db);
  batch.set(doc(db, "messages", messageID), {
    id: messageID,
    senderUserID,
    text: "hello",
    timestamp: serverTimestamp(),
    participants: PARTICIPANTS,
  });
  batch.set(doc(db, "rateLimits", senderUserID), {
    windowStart: serverTimestamp(),
    count: 1,
  });
  return batch.commit();
}

// The app writes its own block list; seeding it directly keeps these tests about
// the message rule rather than the private-profile rule.
async function blocks(ownerID, blockedIDs) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${ownerID}/private/profile`), {
      blockedUserIDs: blockedIDs,
    });
  });
}

// An authenticated context defaults to sign_in_provider "custom", which is not
// "anonymous", so it clears the rules' isFullMember() gate.
const asSender = () => testEnv.authenticatedContext(SENDER).firestore();

describe("messages/{id} create — blocking", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  beforeEach(() => testEnv.clearFirestore());

  // The control. Without it, a rule that denied everything would still pass both
  // negative cases below.
  it("allows a message when neither party has blocked the other", async () => {
    await assertSucceeds(sendMessage(asSender(), SENDER, "m1"));
  });

  // Already enforced before S11; this pins it against regression.
  it("denies a message when the recipient has blocked the sender", async () => {
    await blocks(RECIPIENT, [SENDER]);
    await assertFails(sendMessage(asSender(), SENDER, "m2"));
  });

  // S11. This write was admitted before `blockedEitherWay`: the rule only ever
  // read the recipient's block list, so blocking someone did not stop you from
  // continuing to message them.
  it("denies a message when the sender has blocked the recipient (S11)", async () => {
    await blocks(SENDER, [RECIPIENT]);
    await assertFails(sendMessage(asSender(), SENDER, "m3"));
  });
});

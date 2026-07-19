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
import { swiftStayEventKinds } from "./sources.mjs";

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

// Same as sendMessage but attaches a structured stay `event` (item 29). The
// event travels on the message doc, so it is validated by the same create rule.
function sendMessageWithEvent(db, senderUserID, messageID, event) {
  const batch = writeBatch(db);
  batch.set(doc(db, "messages", messageID), {
    id: messageID,
    senderUserID,
    text: "Requested to stay",
    timestamp: serverTimestamp(),
    participants: PARTICIPANTS,
    event,
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

// item 29: a message may carry a structured stay `event` that the recipient's
// UI renders as a trusted system card. Because the card is trusted, the rule has
// to keep the shape tight — a modified client must not be able to attach an
// arbitrary map, an unknown kind, or extra keys.
describe("messages/{id} create — stay event", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  beforeEach(() => testEnv.clearFirestore());

  // Every kind the Swift client can send, read from StayEvent.Kind in
  // MessageStore.swift rather than listed here by hand. The 'offered' and
  // 'modified' kinds shipped in the client while the rules whitelist still held
  // the original four, so both courtesy notes failed silently in the thread;
  // parsing the enum is what keeps a seventh kind from repeating that.
  for (const kind of swiftStayEventKinds()) {
    it(`allows an event of kind '${kind}'`, async () => {
      await assertSucceeds(
        sendMessageWithEvent(asSender(), SENDER, `e-${kind}`, {
          kind,
          dateRange: "Mar 3 – Mar 6 · 3 nights",
        })
      );
    });
  }

  it("allows an accepted event carrying a host note", async () => {
    await assertSucceeds(
      sendMessageWithEvent(asSender(), SENDER, "e2", {
        kind: "accepted",
        dateRange: "Mar 3 – Mar 6 · 3 nights",
        note: "Door code is 1988.",
      })
    );
  });

  it("denies an event with an unknown kind", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e3", {
        kind: "exploded",
        dateRange: "Mar 3 – Mar 6 · 3 nights",
      })
    );
  });

  it("denies an event missing dateRange", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e4", { kind: "declined" })
    );
  });

  it("denies an event carrying an unexpected key", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e5", {
        kind: "requested",
        dateRange: "Mar 3 – Mar 6 · 3 nights",
        listingID: "sneaky-extra-field",
      })
    );
  });

  it("denies an event that is not a map", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e6", "requested")
    );
  });
});

// Blocking is a rules boundary, not a UI one: the app hides a blocked thread, but a modified
// client can write to `messages` directly. The key case is the S11 regression: the old rule
// checked one direction, so a *blocker* could keep messaging the person they blocked;
// `blockedEitherWay` closes it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, serverTimestamp, setDoc, writeBatch } from "firebase/firestore";
import { swiftStayEventKinds } from "./sources.mjs";

const rulesPath = fileURLToPath(new URL("../firestore.rules", import.meta.url));

// Sorted, as the rules require: participants is always [smaller, larger].
const SENDER = "user-aaaa";
const RECIPIENT = "user-bbbb";
const PARTICIPANTS = [SENDER, RECIPIENT].sort();

let testEnv;

// A message write carries the sender's rate-limit counter in the same commit, since the create rule
// gates on `rateCounterAdvanced`. Mirrors FirestoreMessagesRepository.send's transaction.
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

// Same as sendMessage but with a structured stay `event`, validated by the same create rule.
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

// The app writes its own block list; seeding it directly keeps these tests about the message rule.
async function blocks(ownerID, blockedIDs) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${ownerID}/private/profile`), {
      blockedUserIDs: blockedIDs,
    });
  });
}

// Messaging is friend-gated, so cases expecting a send to succeed seed the edge first (directly, like `blocks`).
async function seedFriendship(a, b, status = "accepted") {
  const [userA, userB] = [a, b].sort();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "friendEdges", `${userA}_${userB}`), {
      userA,
      userB,
      status,
      initiator: userA,
    });
  });
}

// An authenticated context defaults to sign_in_provider "custom", not "anonymous", so it clears isFullMember().
const asSender = () => testEnv.authenticatedContext(SENDER).firestore();

describe("messages/{id} create — blocking", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  beforeEach(async () => {
    await testEnv.clearFirestore();
    // Friends by default; blocking a friend is the ordinary shape of a block.
    await seedFriendship(SENDER, RECIPIENT);
  });

  // The control: a rule denying everything would pass both negative cases below.
  it("allows a message when neither party has blocked the other", async () => {
    await assertSucceeds(sendMessage(asSender(), SENDER, "m1"));
  });

  // Already enforced before S11; pinned against regression.
  it("denies a message when the recipient has blocked the sender", async () => {
    await blocks(RECIPIENT, [SENDER]);
    await assertFails(sendMessage(asSender(), SENDER, "m2"));
  });

  // S11: admitted before `blockedEitherWay`, since the rule read only the recipient's block list.
  it("denies a message when the sender has blocked the recipient (S11)", async () => {
    await blocks(SENDER, [RECIPIENT]);
    await assertFails(sendMessage(asSender(), SENDER, "m3"));
  });
});

// A message may carry a structured stay `event` the recipient's UI renders as a trusted
// card, so the rule keeps the shape tight: no arbitrary map, unknown kind or extra keys.
describe("messages/{id} create — stay event", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  beforeEach(async () => {
    await testEnv.clearFirestore();
    // Friends by default; blocking a friend is the ordinary shape of a block.
    await seedFriendship(SENDER, RECIPIENT);
  });

  // Every kind the Swift client can send, parsed from StayEvent.Kind in MessageStore.swift
  // (the 'offered' and 'modified' kinds once shipped while the whitelist held four, failing silently).
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

  it("allows a hostCancelled event carrying the listing it points back to", async () => {
    // The exact payload StaysTab.hostCancel and MessagingRequestActions build; the kind loop sends only kind+dateRange and missed it.
    await assertSucceeds(
      sendMessageWithEvent(asSender(), SENDER, "e2b", {
        kind: "hostCancelled",
        dateRange: "Mar 3 – Mar 6 · 3 nights",
        note: "Sorry, something came up. Other dates are open.",
        listingID: "listing-1",
      })
    );
  });

  it("denies an event whose listingID is not a document id but an essay", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e2c", {
        kind: "hostCancelled",
        dateRange: "Mar 3 – Mar 6 · 3 nights",
        listingID: "L".repeat(201),
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
        stayID: "sneaky-extra-field",
      })
    );
  });

  it("denies an event that is not a map", async () => {
    await assertFails(
      sendMessageWithEvent(asSender(), SENDER, "e6", "requested")
    );
  });
});

// The friend graph is the trust model and messaging is one of the three things it gates. Sends were
// open to any full member the recipient hadn't blocked, so a stranger knowing a uid could put text on
// their lock screen; hiding the composer isn't a control.
describe("messages/{id} create — friendship", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "freebnb-rules-tests",
      firestore: { rules: readFileSync(rulesPath, "utf8") },
    });
  });

  after(() => testEnv.cleanup());

  // No friendship seeded; each case states its own edge.
  beforeEach(() => testEnv.clearFirestore());

  it("denies a message between strangers", async () => {
    await assertFails(sendMessage(asSender(), SENDER, "f1"));
  });

  it("denies a message when the friend request is still pending", async () => {
    await seedFriendship(SENDER, RECIPIENT, "pending");
    await assertFails(sendMessage(asSender(), SENDER, "f2"));
  });

  it("allows a message between accepted friends", async () => {
    await seedFriendship(SENDER, RECIPIENT);
    await assertSucceeds(sendMessage(asSender(), SENDER, "f3"));
  });

  // The edge id sorts its participants and rules can't sort, so `areFriends` probes both orders; a message from the second uid must clear the same gate.
  it("allows a message from the other side of the same edge", async () => {
    await seedFriendship(SENDER, RECIPIENT);
    const db = testEnv.authenticatedContext(RECIPIENT).firestore();
    await assertSucceeds(sendMessage(db, RECIPIENT, "f4"));
  });

  // Unfriending ends the thread's future, not just hides it.
  it("denies a message once the friendship is removed", async () => {
    await seedFriendship(SENDER, RECIPIENT);
    await assertSucceeds(sendMessage(asSender(), SENDER, "f5"));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await deleteDoc(
        doc(context.firestore(), "friendEdges", `${PARTICIPANTS[0]}_${PARTICIPANTS[1]}`)
      );
    });
    await assertFails(sendMessage(asSender(), SENDER, "f6"));
  });
});

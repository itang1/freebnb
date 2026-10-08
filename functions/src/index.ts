import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError, CallableRequest } from "firebase-functions/v2/https";
// The auth `onDelete` trigger has no v2 equivalent, so that one function stays on v1; v1 and v2 deploy together.
import * as functionsV1 from "firebase-functions/v1";
import {
  Collections,
  Docs,
  Subcollections,
  friendEdgeDocPattern,
  homeDocPattern,
  homePhotosPrefix,
  listingPhotosPrefix,
  messageDocPattern,
  privateProfilePath,
  reviewDocPattern,
  stayRequestDocPattern,
} from "./paths";
import { autoReportReason, scanText } from "./moderation";

admin.initializeApp();

const db = admin.firestore();

// Firestore caps a WriteBatch at 500 operations, and holding an unbounded result set in memory doesn't scale.
const PAGE_SIZE = 500;

// Deletes every document a query matches, one bounded page at a time. Deleted
// documents stop matching, so a retry resumes where it left off. The query must have no `limit`.
async function deleteQueryInChunks(query: FirebaseFirestore.Query): Promise<void> {
  for (;;) {
    const snap = await query.limit(PAGE_SIZE).get();
    if (snap.empty) return;
    const batch = db.batch();
    for (const doc of snap.docs) batch.delete(doc.ref);
    await batch.commit();
    // A short final page means the matched set is drained.
    if (snap.size < PAGE_SIZE) return;
  }
}

// Deletes every Storage object under `prefix` (e.g. listings/{uid}/** on account
// deletion; photos are personal data and a cost leak). A missing bucket or empty prefix is a no-op.
async function deleteStoragePrefix(prefix: string): Promise<void> {
  await admin.storage().bucket().deleteFiles({ prefix });
}

// ---------------------------------------------------------------------------
// Push notifications
// Per-category preferences live in the recipient's private profile as a
// `notificationPrefs` map. A category is enabled unless the map stores `false`
// for it. The client mirror is NotificationCategory in NotificationPreferences.swift.
// ---------------------------------------------------------------------------
type NotificationCategory = "messages" | "stayRequests" | "stayUpdates" | "friendRequests";

function notificationEnabled(
  privateData: FirebaseFirestore.DocumentData | undefined,
  category: NotificationCategory
): boolean {
  const prefs = privateData?.notificationPrefs as Record<string, unknown> | undefined;
  return prefs?.[category] !== false;
}

// Sends one push to `recipientID` for `category`, gated by their preference, block
// list (if `senderID` is given) and FCM token. Any failed gate is a silent no-op,
// including an unreadable private profile.
async function sendPush(opts: {
  recipientID: string;
  category: NotificationCategory;
  senderID?: string;
  title: string;
  body: string;
  data: Record<string, string>;
}): Promise<void> {
  const privateData = (await db.doc(privateProfilePath(opts.recipientID)).get()).data();

  if (!notificationEnabled(privateData, opts.category)) return;
  if (opts.senderID) {
    const blocked: string[] = privateData?.blockedUserIDs ?? [];
    if (blocked.includes(opts.senderID)) return;
  }
  const fcmToken: string | undefined = privateData?.fcmToken;
  if (!fcmToken) return;

  await admin.messaging().send({
    token: fcmToken,
    notification: { title: opts.title, body: opts.body },
    apns: { payload: { aps: { sound: "default" } } },
    data: opts.data,
  });
}

// ---------------------------------------------------------------------------
// scheduledFirestoreBackup: exports all collections to GCS daily at 03:00 UTC.
//
// One-time setup:
//   1. Create a GCS bucket "${PROJECT_ID}-backups" in the same region.
//   2. Grant ${PROJECT_ID}@appspot.gserviceaccount.com storage.admin (on the
//      bucket) and datastore.importExportAdmin (on the project).
//   3. firebase deploy --only functions
// Exports land in gs://${PROJECT_ID}-backups/firestore/YYYY-MM-DD/
// ---------------------------------------------------------------------------
export const scheduledFirestoreBackup = onSchedule(
  { schedule: "0 3 * * *", timeZone: "UTC" },
  async () => {
    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT;
    if (!projectId) throw new Error("GCLOUD_PROJECT env var not set");

    const credential = admin.app().options.credential;
    if (!credential) throw new Error("Firebase Admin credential not initialised");
    const { access_token: accessToken } = await credential.getAccessToken();

    const today = new Date().toISOString().split("T")[0];
    const outputUri = `gs://${projectId}-backups/firestore/${today}`;

    const url =
      `https://firestore.googleapis.com/v1/projects/${projectId}` +
      `/databases/(default):exportDocuments`;

    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ outputUriPrefix: outputUri }),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Firestore export failed (${res.status}): ${body}`);
    }

    const op = await res.json() as { name: string };
    logger.info("Firestore backup started", { operation: op.name, outputUri });
  }
);

// ---------------------------------------------------------------------------
// onMessageCreated
// Maintains the denormalized `conversations/{id}` summary (last message, unread
// counts, mutes) the client's list and badge read from, and pushes to the recipient.
// ---------------------------------------------------------------------------

// Counts the user's unmuted conversations with unread messages (the tab and APNs
// badge value). It queries only conversations already unread for this user
// (`unreadCounts.{uid} > 0`, served by the automatic single-field index) instead of
// paging every thread. Muting is applied in memory, since `mutedBy` is an array
// and can't combine with this filter.
async function unreadConversationCount(userID: string): Promise<number> {
  const snap = await db
    .collection(Collections.conversations)
    .where(new admin.firestore.FieldPath("unreadCounts", userID), ">", 0)
    // A ceiling on pathological mailboxes; nobody reads a badge past PAGE_SIZE.
    .limit(PAGE_SIZE)
    .get();

  let count = 0;
  for (const doc of snap.docs) {
    const muted: string[] = doc.data().mutedBy ?? [];
    if (!muted.includes(userID)) count++;
  }
  return count;
}

export const onMessageCreated = onDocumentCreated(messageDocPattern, async (event) => {
  const snap = event.data;
  if (!snap) return;

  const msg = snap.data() as {
    senderUserID: string;
    participants: string[];
    text: string;
    timestamp: admin.firestore.Timestamp;
  };

  const senderID = msg.senderUserID;
  const recipientID = msg.participants.find((uid) => uid !== senderID);
  if (!recipientID) return;

  // Upsert the summary. The conversationID mirrors the client's MessageStore.conversationID
  // (sorted participants joined by "_"). merge keeps the other side's unread count and
  // mutedBy; the sender is caught up and the recipient's counter advances (a missing counter counts as 0).
  const participants = [...msg.participants].sort();
  const conversationID = participants.join("_");
  const convRef = db.collection(Collections.conversations).doc(conversationID);

  await convRef.set(
    {
      participants,
      lastMessage: {
        text: msg.text,
        senderUserID: senderID,
        timestamp: msg.timestamp,
      },
      updatedAt: msg.timestamp,
      unreadCounts: {
        [senderID]: 0,
        [recipientID]: admin.firestore.FieldValue.increment(1),
      },
    },
    { merge: true }
  );

  // The recipient's token and blocks are in their private subdocument; the sender's name is on the public user doc; mute is on the conversation doc.
  const [recipientPrivate, senderDoc, convSnap] = await Promise.all([
    db.doc(privateProfilePath(recipientID)).get(),
    db.collection(Collections.users).doc(senderID).get(),
    convRef.get(),
  ]);

  // A muted conversation gets no push and doesn't count toward the badge.
  const mutedBy: string[] = convSnap.data()?.mutedBy ?? [];
  if (mutedBy.includes(recipientID)) return;

  const recipientData = recipientPrivate.data();

  // Respect the per-category preference (the unread count still advanced above).
  if (!notificationEnabled(recipientData, "messages")) return;

  // No push from someone the recipient has blocked.
  const blocked: string[] = recipientData?.blockedUserIDs ?? [];
  if (blocked.includes(senderID)) return;

  const fcmToken: string | undefined = recipientData?.fcmToken;
  if (!fcmToken) return;

  const senderName: string = senderDoc.data()?.displayName ?? "FreeBNB";

  // Badge the actual number of unread conversations.
  const badge = await unreadConversationCount(recipientID);

  await admin.messaging().send({
    token: fcmToken,
    notification: {
      title: senderName,
      body: msg.text.length > 120 ? msg.text.slice(0, 120) + "…" : msg.text,
    },
    apns: {
      payload: { aps: { sound: "default", badge } },
    },
    data: { type: "message", senderUserID: senderID },
  });
});

// ---------------------------------------------------------------------------
// Listing read ACLs and the friend graph
//
// `homes.allowedViewerIDs` is the denormalized read ACL firestore.rules uses
// (rules can't join to `friendEdges`). Every listing's audience is host +
// accepted friends; friends-of-friends see only a friend suggestion (see
// suggestFriends) and gain access once the host accepts them. The client stamps
// the same array on save and `onHomeWrittenACL` repairs drift. Everything here
// rebuilds the array from the graph rather than applying a delta, so retries are
// idempotent. Legacy `visibility` is ignored (scripts/migrate_friends_only.js strips it).
// ---------------------------------------------------------------------------
type FriendEdgeData = { userA: string; userB: string; status?: string; initiator?: string };

// The rules cap `allowedViewerIDs` at 1000 and the array downloads with every feed
// document, so a very well-connected host's list is truncated.
const ACL_CAP = 1000;

/** Accepted friends of one user, read from both halves of the edge. */
async function acceptedFriendsOf(userID: string): Promise<string[]> {
  const [aSnap, bSnap] = await Promise.all([
    db.collection(Collections.friendEdges).where("userA", "==", userID).where("status", "==", "accepted").get(),
    db.collection(Collections.friendEdges).where("userB", "==", userID).where("status", "==", "accepted").get(),
  ]);
  return [...aSnap.docs.map((d) => d.data().userB as string), ...bSnap.docs.map((d) => d.data().userA as string)];
}

/** Order-insensitive set equality, so a rebuild that changes nothing writes nothing. */
function sameMembers(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const set = new Set(a);
  return b.every((id) => set.has(id));
}

/**
 * Recomputes `allowedViewerIDs` for every listing hosted by `hostID` (or just
 * one, when `onlyHomeID` is given) and writes back only the documents whose ACL
 * actually changed.
 *
 * Writing only on a real change is what keeps `onHomeWrittenACL` from looping:
 * its own update re-fires the trigger, the second pass computes the same array,
 * and the recursion stops there.
 */
async function rebuildListingACLs(hostID: string, onlyHomeID?: string): Promise<void> {
  const friends = await acceptedFriendsOf(hostID);

  // Every listing carries the same ACL; the host is always in it (the rules refuse self-lockout).
  const desired = [...new Set([hostID, ...friends])].slice(0, ACL_CAP);

  // Updating one listing reads one document, not the whole catalogue.
  if (onlyHomeID) {
    const ref = db.collection(Collections.homes).doc(onlyHomeID);
    const snap = await ref.get();
    if (!snap.exists) return;
    const data = snap.data() as FirebaseFirestore.DocumentData;
    if (sameMembers(data.allowedViewerIDs ?? [], desired)) return;
    await ref.update({ allowedViewerIDs: desired });
    return;
  }

  const base = db
    .collection(Collections.homes)
    .where("hostUserID", "==", hostID)
    .orderBy(admin.firestore.FieldPath.documentId());

  let cursor: string | undefined;
  for (;;) {
    let query = base.limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) return;

    const batch = db.batch();
    let writes = 0;
    for (const doc of snap.docs) {
      const data = doc.data();
      if (sameMembers(data.allowedViewerIDs ?? [], desired)) continue;
      batch.update(doc.ref, { allowedViewerIDs: desired });
      writes++;
    }
    if (writes > 0) await batch.commit();

    if (snap.size < PAGE_SIZE) return;
    cursor = snap.docs[snap.docs.length - 1].id;
  }
}

// ---------------------------------------------------------------------------
// onFriendEdgeWritten
// A listing's audience is its host's accepted friends, so an edge changing
// accepted-ness moves only the two endpoints' ACLs. It also sends the friend
// graph's two pushes, which sit on a new user's critical path: the app is empty
// until someone accepts them.
// ---------------------------------------------------------------------------
export const onFriendEdgeWritten = onDocumentWritten(friendEdgeDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? (change.before.data() as FriendEdgeData) : undefined;
  const after = change?.after.exists ? (change.after.data() as FriendEdgeData) : undefined;

  await notifyFriendEdge(before, after);

  const wasFriends = before?.status === "accepted";
  const isFriends = after?.status === "accepted";
  if (wasFriends === isFriends) return;

  const edge = after ?? before;
  if (!edge?.userA || !edge?.userB) return;

  await Promise.all([edge.userA, edge.userB].map((hostID) => rebuildListingACLs(hostID)));

  // A new friendship needs a circle membership on each side, since an absent one is a
  // gap rather than being in Default. Clients do this when Friends next appears; this
  // covers the window in between and the side whose app isn't running.
  if (isFriends) {
    await Promise.all([
      placeInDefaultCircle(edge.userA, edge.userB),
      placeInDefaultCircle(edge.userB, edge.userA),
    ]);
  }
});

// ---------------------------------------------------------------------------
// Circles
// The functions' share is repair, never enforcement: firestore.rules is the
// boundary, since no functions are deployed in production. See docs/internal/CIRCLES.md.
// ---------------------------------------------------------------------------

type BookingPolicyData = {
  allowedArrivalOptions: string[];
  minNoticeHours: number;
  maxStaysPerPeriod: { count: number; periodDays: number } | null;
};

const circlePath = (hostID: string, circleID: string) =>
  db.collection(Collections.users).doc(hostID).collection(Subcollections.circles).doc(circleID);

/**
 * Files `friendID` under `hostID`'s Default circle, and publishes the policy
 * that circle implies to the projection the friend's client reads.
 *
 * Does nothing when a membership already exists: the host may have moved this
 * person deliberately, and a friendship that flickers off and on again must not
 * quietly undo that.
 */
async function placeInDefaultCircle(hostID: string, friendID: string): Promise<void> {
  const memberRef = db
    .collection(Collections.users)
    .doc(hostID)
    .collection(Subcollections.circleMembers)
    .doc(friendID);
  if ((await memberRef.get()).exists) return;

  // No Default circle means no circles at all; their client seeds them on next launch, and until then nothing is restricted.
  const defaultCircle = await circlePath(hostID, Docs.defaultCircle).get();
  const policy = defaultCircle.data()?.policy as BookingPolicyData | undefined;
  if (!policy) return;

  await Promise.all([
    memberRef.set({
      circleID: Docs.defaultCircle,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }),
    db
      .collection(Collections.users)
      .doc(hostID)
      .collection(Subcollections.bookingPolicies)
      .doc(friendID)
      .set(policy),
  ]);
}

/** The display name on a user's public doc, or a neutral stand-in. */
async function displayNameOf(userID: string, fallback: string): Promise<string> {
  const doc = await db.collection(Collections.users).doc(userID).get();
  const name: unknown = doc.data()?.displayName;
  return typeof name === "string" && name.length > 0 ? name : fallback;
}

// The two friend-graph moments worth a push: a request arriving and one being
// accepted. A decline or unfriend is silence on purpose, since being turned down invites a second ask.
async function notifyFriendEdge(
  before: FriendEdgeData | undefined,
  after: FriendEdgeData | undefined
): Promise<void> {
  if (!after?.userA || !after?.userB || !after.initiator) return;
  const initiator = after.initiator;
  const recipient = after.userA === initiator ? after.userB : after.userA;

  // A new pending edge: the asked person has no other way to find out.
  if (!before && after.status === "pending") {
    const senderName = await displayNameOf(initiator, "Someone");
    await sendPush({
      recipientID: recipient,
      category: "friendRequests",
      senderID: initiator,
      // An ask, not a claim; declining is a good answer.
      title: "Friend request",
      body: `${senderName} would like to connect on FreeBNB.`,
      data: { type: "friend_request", senderUserID: initiator },
    });
    return;
  }

  // Accepted: tell the asker, whose feed just went from empty to not.
  if (before?.status === "pending" && after.status === "accepted") {
    const accepterName = await displayNameOf(recipient, "A friend");
    await sendPush({
      recipientID: initiator,
      category: "friendRequests",
      senderID: recipient,
      title: `${accepterName} accepted your request`,
      body: "You can see each other's places now.",
      data: { type: "friend_accepted", senderUserID: recipient },
    });
  }
}

// ---------------------------------------------------------------------------
// onHomeWrittenACL: repairs any listing whose ACL drifted (stale client, partial
// write). Separate from onHomeDeleted so each is about one thing.
// ---------------------------------------------------------------------------
export const onHomeWrittenACL = onDocumentWritten(homeDocPattern, async (event) => {
  const after = event.data?.after.exists ? event.data.after.data() : undefined;
  if (!after) return; // deletes are onHomeDeleted's business
  const hostUserID: string | undefined = after.hostUserID;
  if (!hostUserID) return;

  await rebuildListingACLs(hostUserID, event.params.homeID);
});

// ---------------------------------------------------------------------------
// Trust stats
// The reputation numbers on `users/{uid}.trustStats`, recomputed from scratch
// whenever a stay or review moves, never incremented (a retry would inflate a
// record permanently). firestore.rules pins them against clients, so only this
// admin-credentialed function moves them.
// ---------------------------------------------------------------------------

type TrustStats = {
  staysHosted: number;
  staysTaken: number;
  reviewCount: number;
  averageRating: number | null;
};

async function recomputeTrustStats(userID: string): Promise<void> {
  const [asHost, asGuest, aboutThem] = await Promise.all([
    db.collection(Collections.stayRequests).where("hostUserID", "==", userID).get(),
    db.collection(Collections.stayRequests).where("guestUserID", "==", userID).get(),
    db.collection(Collections.reviews).where("subjectUserID", "==", userID).get(),
  ]);

  // A stay that happened is a stay hosted, whoever proposed it.
  const staysHosted = asHost.docs.filter((d) => d.data().status === "completed").length;
  const staysTaken = asGuest.docs.filter((d) => d.data().status === "completed").length;

  const ratings = aboutThem.docs.map((d) => d.data().rating as number).filter((r) => typeof r === "number");
  const averageRating = ratings.length > 0
    ? ratings.reduce((sum, r) => sum + r, 0) / ratings.length
    : null;

  const stats: TrustStats = {
    staysHosted,
    staysTaken,
    reviewCount: ratings.length,
    averageRating,
  };

  // Never resurrect a deleted account as a stats-only doc; the public user doc must carry a displayName.
  const userRef = db.collection(Collections.users).doc(userID);
  if (!(await userRef.get()).exists) return;
  await userRef.set({ trustStats: stats }, { merge: true });
}

// ---------------------------------------------------------------------------
// onReviewWritten: a review changes the reviewed person's rating, so recompute their stats.
// ---------------------------------------------------------------------------
export const onReviewWritten = onDocumentWritten(reviewDocPattern, async (event) => {
  const change = event.data;
  const subjectUserID: string | undefined =
    (change?.after.exists ? change.after.data() : change?.before.data())?.subjectUserID;
  if (!subjectUserID) return;
  await recomputeTrustStats(subjectUserID);
});

// ---------------------------------------------------------------------------
// Keyword moderation
// Nothing is blocked or hidden: a hit files a report tagged `source: "auto"`.
// A false positive costs a moderator a click; a silent false negative would cost
// a user their conversation. The report id derives from the target, so retries
// and re-edits overwrite the open report rather than duplicating it.
// ---------------------------------------------------------------------------
async function fileAutoReport(opts: {
  targetType: "user" | "listing" | "message";
  targetID: string;
  authorUserID: string;
  reason: string;
}): Promise<void> {
  await db.collection(Collections.reports).doc(`auto_${opts.targetType}_${opts.targetID}`).set({
    reporterUserID: opts.authorUserID,
    targetType: opts.targetType,
    targetID: opts.targetID,
    reason: opts.reason,
    status: "new",
    source: "auto",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  logger.info("Auto-filed moderation report", { targetType: opts.targetType, targetID: opts.targetID });
}

export const moderateNewMessage = onDocumentCreated(messageDocPattern, async (event) => {
  const msg = event.data?.data();
  if (!msg) return;
  const hit = scanText(msg.text);
  if (!hit) return;
  await fileAutoReport({
    targetType: "message",
    targetID: event.params.messageID,
    authorUserID: msg.senderUserID,
    reason: autoReportReason(hit),
  });
});

export const moderateListingContent = onDocumentWritten(homeDocPattern, async (event) => {
  const after = event.data?.after.exists ? event.data.after.data() : undefined;
  if (!after || after.deletedAt) return;
  // The free-text fields a host controls; structured fields are enum-validated by the rules.
  const hit = scanText([after.description, after.hostContactInfo, after.hostName].filter(Boolean).join("\n"));
  if (!hit) return;
  await fileAutoReport({
    targetType: "listing",
    targetID: event.params.homeID,
    authorUserID: after.hostUserID,
    reason: autoReportReason(hit),
  });
});

// ---------------------------------------------------------------------------
/**
 * The calling uid, or a thrown error.
 *
 * Every callable checked `request.auth` and stopped there, which is a weaker
 * gate than the one `firestore.rules` applies to the same people: `isFullMember`
 * also excludes anonymous browse-only sessions, which the rules treat as
 * read-only throughout. Nothing was reachable through the gap — an anonymous
 * account owns no stay requests and no friend edges, so every callable already
 * returned nothing to one — but the two boundaries should say the same thing
 * before a later callable makes the difference matter.
 *
 * Callables are also declared with `enforceAppCheck`, which is the other half:
 * firestore.rules names App Check as its primary control against a hand-rolled
 * client in two places, and a callable that skipped it would be the way around
 * both. Note that Firestore-side App Check enforcement is a console setting, not
 * anything in this repo — see docs/internal/TODO.md.
 */
function requireFullMember(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  if (request.auth?.token?.firebase?.sign_in_provider === "anonymous") {
    throw new HttpsError("permission-denied", "This needs a full account.");
  }
  return uid;
}

/** Applied to every callable below. See `requireFullMember`. */
const callableOptions = { enforceAppCheck: true } as const;

// ---------------------------------------------------------------------------
// mutualFriends (callable)
// "You and Priya have 3 friends in common". Server-side because `friendEdges`
// are readable only by their two users. Call: httpsCallable("mutualFriends").call(["userID": id])
// ---------------------------------------------------------------------------
export const mutualFriends = onCall(callableOptions, async (request) => {
  const uid = requireFullMember(request);

  const otherID: unknown = request.data?.userID;
  if (typeof otherID !== "string" || otherID.length === 0) {
    throw new HttpsError("invalid-argument", "userID is required.");
  }
  if (otherID === uid) return { count: 0, names: [] };

  const [mine, theirs] = await Promise.all([acceptedFriendsOf(uid), acceptedFriendsOf(otherID)]);
  const mineSet = new Set(mine);
  const shared = [...new Set(theirs.filter((id) => mineSet.has(id)))];

  // Only a couple of names are rendered, so resolve only those.
  const NAMES_SHOWN = 2;
  const names = await Promise.all(
    shared.slice(0, NAMES_SHOWN).map(async (friendID) => {
      const snap = await db.collection(Collections.users).doc(friendID).get();
      return (snap.data()?.displayName as string) ?? "FreeBNB User";
    })
  );

  return { count: shared.length, names };
});

// ---------------------------------------------------------------------------
// onUserDeleted
// Server-side cascade when a Firebase Auth user is removed; a safety net for
// deletions bypassing the client. Stays on v1 (no v2 post-delete auth trigger).
// ---------------------------------------------------------------------------
export const onUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;

  // Soft-delete the user's listings (kept for history), chunked under the 500-op batch cap.
  const listingsSnap = await db.collection(Collections.homes).where("hostUserID", "==", uid).get();
  for (let i = 0; i < listingsSnap.docs.length; i += PAGE_SIZE) {
    const batch = db.batch();
    const now = admin.firestore.FieldValue.serverTimestamp();
    for (const doc of listingsSnap.docs.slice(i, i + PAGE_SIZE)) {
      batch.update(doc.ref, { deletedAt: now });
    }
    await batch.commit();
  }

  // The listing survives as history but its street address must not: drop each
  // private location and access marker, and revoke addresses held as a guest.
  await Promise.all([
    ...listingsSnap.docs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.private))),
    ...listingsSnap.docs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.accepted))),
    deleteQueryInChunks(db.collectionGroup(Subcollections.accepted).where("guestUserID", "==", uid)),
    // Listing photos live in Storage, so the document cascade misses them; drop listings/{uid}/.
    deleteStoragePrefix(listingPhotosPrefix(uid)),
  ]);

  // Reviews and references naming this user go too (written and received), plus
  // each review's private/feedback subdocument, which Firestore would strand.
  const reviewAndReferenceDocs = await Promise.all([
    db.collection(Collections.reviews).where("authorUserID", "==", uid).get(),
    db.collection(Collections.reviews).where("subjectUserID", "==", uid).get(),
    db.collection(Collections.references).where("authorUserID", "==", uid).get(),
    db.collection(Collections.references).where("subjectUserID", "==", uid).get(),
  ]);
  const reviewDocs = [...reviewAndReferenceDocs[0].docs, ...reviewAndReferenceDocs[1].docs];
  await Promise.all(reviewDocs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.private))));

  // Everyone whose reputation partly came from this user; collected before deleting, recomputed after.
  const [guestStays, hostStays] = await Promise.all([
    db.collection(Collections.stayRequests).where("guestUserID", "==", uid).get(),
    db.collection(Collections.stayRequests).where("hostUserID", "==", uid).get(),
  ]);
  const counterparties = new Set<string>();
  const remember = (id: unknown) => {
    if (typeof id === "string" && id.length > 0 && id !== uid) counterparties.add(id);
  };
  for (const doc of reviewDocs) {
    remember(doc.data().authorUserID);
    remember(doc.data().subjectUserID);
  }
  for (const doc of [...guestStays.docs, ...hostStays.docs]) {
    remember(doc.data().hostUserID);
    remember(doc.data().guestUserID);
  }

  await Promise.all(
    reviewAndReferenceDocs.flatMap((snap) =>
      snap.docs.map((doc) => doc.ref.delete())
    )
  );

  // Hard-cascade the user's messages (only ones they authored), stay requests,
  // friend edges and reports so no personal data is left.
  await Promise.all([
    deleteQueryInChunks(db.collection(Collections.messages).where("senderUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.stayRequests).where("guestUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.stayRequests).where("hostUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.friendEdges).where("userA", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.friendEdges).where("userB", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.reports).where("reporterUserID", "==", uid)),
    // Summaries carry the user's name and unread/mute state; drop them, and the other party's next message rebuilds each.
    deleteQueryInChunks(db.collection(Collections.conversations).where("participants", "array-contains", uid)),
  ]);

  // Finally remove the private subdocument and the public user document.
  await db.doc(privateProfilePath(uid)).delete();
  await db.collection(Collections.users).doc(uid).delete();

  // Stay-request deletions don't fire `onStayRequestWritten`, so counterparties'
  // stats would keep counting this person; `recomputeTrustStats` skips deleted users.
  await Promise.all([...counterparties].map((id) => recomputeTrustStats(id)));
});

// ---------------------------------------------------------------------------
// onHomeDeleted
// Deleting a listing reached neither its Storage objects nor subcollections.
// Photos are the sharper leak: storage.rules lets any signed-in user read
// `listings/{uid}/{homeID}/**`, so a delisted home kept serving them.
//
// Two ways a listing goes away:
//   - Hard delete: Firestore leaves subcollections behind (`private/location`,
//     `accepted/`). Unreadable once the parent is gone, but the address still
//     sits there, so drop it with the photos.
//   - Soft delete (`deletedAt` unset to set; the client's path): photos go, but
//     `private/location` and `accepted/` stay, since a guest may be mid-stay and
//     `expireCompletedStays` revokes those markers afterwards.
//
// Every branch is idempotent, so retries and the duplicate fire from
// `onUserDeleted` are safe.
// ---------------------------------------------------------------------------
export const onHomeDeleted = onDocumentWritten(homeDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? change.before.data() : undefined;
  const after = change?.after.exists ? change.after.data() : undefined;
  if (!before) return; // a create has nothing to clean up

  const hardDeleted = !after;
  const softDeleted = !!after && !before.deletedAt && !!after.deletedAt;
  if (!hardDeleted && !softDeleted) return;

  const homeID = event.params.homeID;
  const hostUserID: string | undefined = (after ?? before).hostUserID;
  // A listing with no host has no photo prefix to target.
  if (!hostUserID) return;

  const homeRef = db.collection(Collections.homes).doc(homeID);
  await Promise.all([
    deleteStoragePrefix(homePhotosPrefix(hostUserID, homeID)),
    ...(hardDeleted
      ? [
        deleteQueryInChunks(homeRef.collection(Subcollections.private)),
        deleteQueryInChunks(homeRef.collection(Subcollections.accepted)),
      ]
      : []),
  ]);

  logger.info("Cleaned up deleted listing", { homeID, hostUserID, hardDeleted });
});

// ---------------------------------------------------------------------------
// acceptStayRequest (callable)
// Owns stay acceptance so the double-booking guard is race-free: the read-check-write
// runs in one Firestore transaction (the admin SDK can query inside one, the iOS
// client can't), along with the address-disclosure marker.
//
// Works both ways: a "pending" request is accepted by the host, an "offered" one
// by the guest. Both run the same overlap check; the guest needs it more, since
// the rules let them read only their own requests. Call: httpsCallable("acceptStayRequest").call(["requestID": id])
// ---------------------------------------------------------------------------
export const acceptStayRequest = onCall(callableOptions, async (request) => {
  const uid = requireFullMember(request);

  const requestID: unknown = request.data?.requestID;
  const hostNote: unknown = request.data?.hostNote;
  if (typeof requestID !== "string" || requestID.length === 0) {
    throw new HttpsError("invalid-argument", "requestID is required.");
  }
  if (hostNote !== undefined && typeof hostNote !== "string") {
    throw new HttpsError("invalid-argument", "hostNote must be a string.");
  }
  // Admin writes bypass the rules, so re-enforce the 2000-char hostNote cap here.
  if (typeof hostNote === "string" && hostNote.length > 2000) {
    throw new HttpsError("invalid-argument", "hostNote is too long.");
  }

  const requestRef = db.collection(Collections.stayRequests).doc(requestID);

  await db.runTransaction(async (t) => {
    const reqSnap = await t.get(requestRef);
    if (!reqSnap.exists) {
      throw new HttpsError("not-found", "Request no longer exists.");
    }
    const req = reqSnap.data() as {
      hostUserID: string;
      guestUserID: string;
      listingID: string;
      status: string;
      checkIn: admin.firestore.Timestamp;
      checkOut: admin.firestore.Timestamp;
    };
    // Read before the authorization check because the host side includes co-hosts,
    // whose roster is on the listing. The checks still run in order, so an
    // unauthorized caller learns nothing about the listing.
    const listingSnap = await t.get(db.collection(Collections.homes).doc(req.listingID));
    const coHostUserIDs = (listingSnap.data()?.coHostUserIDs ?? []) as string[];
    // Mirrors isHostSide() in firestore.rules: the named host or a co-host. Keep them in step.
    const isHostSide = req.hostUserID === uid || coHostUserIDs.includes(uid);

    // Whoever is owed the answer may say yes (host side on a request, guest on an
    // offer); anyone else, including the sender, is refused, so a host can't accept
    // their own offer on the guest's behalf.
    if (req.status === "pending") {
      if (!isHostSide) {
        throw new HttpsError("permission-denied", "Only the host or a co-host can accept this request.");
      }
      // A co-host may ask to stay at a listing they help run, putting them on both
      // sides of one document. Refuse self-acceptance, which would mint a completed
      // stay and trust stats from one person agreeing with themselves.
      if (req.guestUserID === uid) {
        throw new HttpsError("permission-denied", "You cannot accept your own request.");
      }
    } else if (req.status === "offered") {
      if (req.guestUserID !== uid) {
        throw new HttpsError("permission-denied", "Only the guest can accept this offer.");
      }
    } else {
      throw new HttpsError("failed-precondition", "This stay is no longer awaiting an answer.");
    }
    // A hostNote is the host's to write; on an offer they wrote one at create time, which the guest mustn't overwrite.
    if (req.status === "offered" && typeof hostNote === "string") {
      throw new HttpsError("invalid-argument", "A guest cannot write the host's note.");
    }

    // The listing must still exist and be live; accepting for a deleted listing would disclose an address nothing cleans up.
    if (!listingSnap.exists || listingSnap.data()?.deletedAt) {
      throw new HttpsError("failed-precondition", "This listing is no longer available.");
    }

    // Reads precede writes in a transaction. Re-read the accepted requests inside it
    // so a concurrent accept that committed first blocks this one. The turnover buffer
    // comes from the managers-only availability document.
    const [accepted, availabilitySnap] = await Promise.all([
      t.get(
        db.collection(Collections.stayRequests)
          .where("listingID", "==", req.listingID)
          .where("status", "==", "accepted")
      ),
      t.get(
        db.collection(Collections.homes).doc(req.listingID)
          .collection(Subcollections.private).doc(Docs.availability)
      ),
    ]);
    const bufferHours = (availabilitySnap.data()?.bufferHours ?? DEFAULT_BUFFER_HOURS) as number;
    const padMs = bufferDaysForHours(bufferHours) * MS_PER_DAY;
    const inMs = req.checkIn.toMillis();
    const outMs = req.checkOut.toMillis();
    for (const doc of accepted.docs) {
      if (doc.id === requestID) continue;
      const other = doc.data() as { checkIn: admin.firestore.Timestamp; checkOut: admin.firestore.Timestamp };
      // Half-open overlap of this stay's raw dates against the other stay grown by
      // the buffer on both sides. Padding only the existing stay avoids demanding two buffers between neighbours.
      if (other.checkIn.toMillis() - padMs < outMs && inMs < other.checkOut.toMillis() + padMs) {
        // "aborted" (not "failed-precondition") lets the client tell a double-booking from not-pending.
        throw new HttpsError(
          "aborted",
          "Those dates overlap a stay already accepted for this listing."
        );
      }
    }

    // Accept and disclose the address in one atomic write.
    t.update(requestRef, {
      status: "accepted",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(typeof hostNote === "string" ? { hostNote } : {}),
    });
    t.set(db.collection(Collections.homes).doc(req.listingID).collection(Subcollections.accepted).doc(req.guestUserID), {
      requestID,
      guestUserID: req.guestUserID,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { ok: true };
});

// ---------------------------------------------------------------------------
// Booked dates
// The listing publishes the ranges its accepted stays took as "unavailable",
// indistinguishable from a host-blocked day. A display cache: the real guard is
// the acceptStayRequest transaction. Recomputed from scratch on every
// accepted-stay change, like trust stats and ACLs, so retries can't drift it.
// ---------------------------------------------------------------------------

/** Mirrors isOptionalList(data, 'bookedDateRanges', 100) in firestore.rules. */
const BOOKED_RANGES_CAP = 100;

type StoredRange = { start: admin.firestore.Timestamp; end: admin.firestore.Timestamp };

function sameStoredRanges(a: StoredRange[], b: StoredRange[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].start.toMillis() !== b[i].start.toMillis()) return false;
    if (a[i].end.toMillis() !== b[i].end.toMillis()) return false;
  }
  return true;
}

// The turnover buffer assumed when availability never set one; mirrors
// ListingAvailability.defaultBufferHours, so older listings still hold a day around bookings.
const DEFAULT_BUFFER_HOURS = 24;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

// Whole turnover days a buffer of `hours` implies, rounded up since the calendar is
// day-granular. Mirrors AvailabilityCalendar.bufferDays(forHours:).
function bufferDaysForHours(hours: number): number {
  return hours > 0 ? Math.ceil(hours / 24) : 0;
}

// Each booked range grown by the buffer on both sides, then merged, so the
// published calendar closes the days around a stay like any other unavailable day.
// Mirrors AvailabilityCalendar.buffered(_:bufferHours:); a zero buffer changes nothing.
function bufferedStoredRanges(ranges: StoredRange[], bufferHours: number): StoredRange[] {
  const days = bufferDaysForHours(bufferHours);
  if (days <= 0) return ranges;
  const padMs = days * MS_PER_DAY;
  const padded = ranges
    .map((r) => ({ start: r.start.toMillis() - padMs, end: r.end.toMillis() + padMs }))
    .sort((a, b) => a.start - b.start);
  const merged: { start: number; end: number }[] = [];
  for (const r of padded) {
    const last = merged[merged.length - 1];
    if (last && r.start <= last.end) last.end = Math.max(last.end, r.end);
    else merged.push({ ...r });
  }
  return merged.map((r) => ({
    start: admin.firestore.Timestamp.fromMillis(r.start),
    end: admin.firestore.Timestamp.fromMillis(r.end),
  }));
}

async function recomputeListingBookedRanges(listingID: string): Promise<void> {
  const listingRef = db.collection(Collections.homes).doc(listingID);
  const availabilityRef = listingRef
    .collection(Subcollections.private)
    .doc(Docs.availability);
  const [listingSnap, availabilitySnap, acceptedSnap] = await Promise.all([
    listingRef.get(),
    availabilityRef.get(),
    db
      .collection(Collections.stayRequests)
      .where("listingID", "==", listingID)
      .where("status", "==", "accepted")
      .get(),
  ]);
  // Nothing to publish onto a deleted listing; writing would resurrect fields onHomeDeleted is retiring.
  if (!listingSnap.exists || listingSnap.data()?.deletedAt) return;

  // One range per accepted stay; they never overlap (the accept guard forbids it), so
  // sorting just keeps the write stable for the change-check below.
  type StayDates = { checkIn: admin.firestore.Timestamp; checkOut: admin.firestore.Timestamp };
  const ranges: StoredRange[] = acceptedSnap.docs
    .map((d) => d.data() as { checkIn?: admin.firestore.Timestamp; checkOut?: admin.firestore.Timestamp })
    .filter((r): r is StayDates => !!r.checkIn && !!r.checkOut)
    .map((r) => ({ start: r.checkIn, end: r.checkOut }))
    .sort((a, b) => a.start.toMillis() - b.start.toMillis())
    .slice(0, BOOKED_RANGES_CAP);

  const existing = (availabilitySnap.data()?.bookedDateRanges ?? []) as StoredRange[];
  const blocked = (availabilitySnap.data()?.blockedDateRanges ?? []) as StoredRange[];
  const bufferHours = (availabilitySnap.data()?.bufferHours ?? DEFAULT_BUFFER_HOURS) as number;
  if (sameStoredRanges(existing, ranges)) return;

  // Two writes, since availability is stored twice on purpose: the halves
  // privately for managers, their union on the readable listing (publishing the
  // halves would reveal which nights were occupied). Private first: it's the source
  // of truth, and a crash between the two leaves the truth written and the cache
  // stale until the next change.
  await availabilityRef.set({ bookedDateRanges: ranges }, { merge: true });

  // A field update, not a set, so the listing's other fields and ACL survive. This
  // fires onHomeWrittenACL and moderateListingContent, but neither writes back for
  // an availability change, so there's no loop. Sorted for a stable write. The
  // booked half is grown by the buffer before merging, so the public calendar carries
  // it while `bookedDateRanges` stays the raw stays; a cancellation releases it for free.
  const union = [...blocked, ...bufferedStoredRanges(ranges, bufferHours)].sort(
    (a, b) => a.start.toMillis() - b.start.toMillis()
  );
  await listingRef.update({ unavailableDateRanges: union });
}

// ---------------------------------------------------------------------------
// onStayRequestWritten
// Stay-lifecycle pushes with a deep link into the Stays tab: the host hears of a
// new request, the guest of an accept or decline. Courtesy notes in the thread use
// the "messages" category; these use "stayRequests"/"stayUpdates" so each mutes separately.
// ---------------------------------------------------------------------------
export const onStayRequestWritten = onDocumentWritten(stayRequestDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? change.before.data() : undefined;
  const after = change?.after.exists ? change.after.data() : undefined;

  // Keep the listing's published booked dates in step with accepted stays. Runs before
  // the notification bail-outs and on deletions too, so a booked range never outlives
  // its stay: any accept, cancel, decline, completion or date change touches an 'accepted' status.
  const bookedListingID: string | undefined = after?.listingID ?? before?.listingID;
  if (bookedListingID && (before?.status === "accepted" || after?.status === "accepted")) {
    await recomputeListingBookedRanges(bookedListingID);
  }

  if (!after) return; // a deletion has no one to notify

  const requestID = event.params.requestID;
  const listingCity: string = after.listingCity ?? "";
  const listingTitle: string = after.listingTitle ?? "";
  const guestUserID: string = after.guestUserID;
  const hostUserID: string = after.hostUserID;
  const beforeStatus: string | undefined = before?.status;
  const afterStatus: string = after.status;
  // Name the home when the host titled it (one host can list several); otherwise the city.
  const placeSuffix = listingTitle
    ? ` for ${listingTitle}`
    : listingCity
    ? ` in ${listingCity}`
    : "";

  // Hosted and taken stays count only completions, so only a transition into or out
  // of 'completed' moves either number; a recompute is six queries, so skip the rest.
  if (beforeStatus !== afterStatus && (beforeStatus === "completed" || afterStatus === "completed")) {
    await Promise.all([recomputeTrustStats(hostUserID), recomputeTrustStats(guestUserID)]);
  }

  // A new pending request: notify the host.
  if (!before && afterStatus === "pending") {
    const guestName =
      (await db.collection(Collections.users).doc(guestUserID).get()).data()?.displayName ?? "Someone";
    await sendPush({
      recipientID: hostUserID,
      category: "stayRequests",
      senderID: guestUserID,
      title: "New stay request",
      body: `${guestName} asked to stay${placeSuffix}.`,
      data: { type: "stay_request", requestID, role: "host" },
    });
    return;
  }

  // A new offer: notify the guest. The one push that isn't a reply to something the
  // recipient did. Rides "stayRequests" like a request, and is phrased as an offer, not a summons.
  if (!before && afterStatus === "offered") {
    const hostName: string = after.listingHostName ?? "A friend";
    await sendPush({
      recipientID: guestUserID,
      category: "stayRequests",
      senderID: hostUserID,
      title: "A friend offered you their place",
      body: `${hostName} has space${placeSuffix} and thought of you.`,
      data: { type: "stay_request", requestID, role: "guest" },
    });
    return;
  }

  // Either party called the stay off: tell the other, on "stayUpdates" like the
  // accept and decline. `cancelledBy` is written with the status and pinned by the
  // rules; it's absent on older cancellations, so nothing is sent for those.
  if (beforeStatus !== "cancelled" && afterStatus === "cancelled") {
    const cancelledBy: string | undefined = after.cancelledBy;
    if (!cancelledBy) return;
    const cancelledByHost = cancelledBy === hostUserID;
    const recipientID = cancelledByHost ? guestUserID : hostUserID;
    const hostName: string = after.listingHostName ?? "The host";
    const guestName =
      (await db.collection(Collections.users).doc(guestUserID).get()).data()?.displayName ?? "Your guest";

    // A host calling off a confirmed stay is the one cancellation the guest was counting
    // on, so it gets its own copy (the host had to; other dates are theirs to look at).
    // Every other cancel keeps the plain copy below.
    if (cancelledByHost && beforeStatus === "accepted") {
      await sendPush({
        recipientID: guestUserID,
        category: "stayUpdates",
        senderID: cancelledBy,
        title: "Your host had to cancel",
        body: `${hostName} had to cancel your stay${placeSuffix}. You can look at their other dates whenever you're ready.`,
        data: { type: "stay_update", requestID, role: "guest", status: "cancelled" },
      });
      return;
    }

    await sendPush({
      recipientID,
      category: "stayUpdates",
      senderID: cancelledBy,
      title: "Stay cancelled",
      body: cancelledByHost
        ? `${hostName} can no longer host your stay${placeSuffix}.`
        : `${guestName} cancelled their stay${placeSuffix}.`,
      data: { type: "stay_update", requestID, role: cancelledByHost ? "guest" : "host", status: "cancelled" },
    });
    return;
  }

  // The host resolved a pending request: notify the guest.
  if (beforeStatus === "pending" && afterStatus !== "pending") {
    const hostName: string = after.listingHostName ?? "The host";
    if (afterStatus === "accepted") {
      await sendPush({
        recipientID: guestUserID,
        category: "stayUpdates",
        senderID: hostUserID,
        title: "Stay accepted 🎉",
        body: `${hostName} accepted your request${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "guest", status: "accepted" },
      });
    } else if (afterStatus === "declined") {
      await sendPush({
        recipientID: guestUserID,
        category: "stayUpdates",
        senderID: hostUserID,
        title: "Stay request update",
        body: `${hostName} couldn't host your request${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "guest", status: "declined" },
      });
    }
    return;
  }

  // The guest answered a host's offer: notify the host, who'd otherwise hear nothing back.
  if (beforeStatus === "offered" && afterStatus !== "offered") {
    const guestName =
      (await db.collection(Collections.users).doc(guestUserID).get()).data()?.displayName ?? "Your friend";
    if (afterStatus === "accepted") {
      await sendPush({
        recipientID: hostUserID,
        category: "stayUpdates",
        senderID: guestUserID,
        title: "Offer accepted 🎉",
        body: `${guestName} is coming to stay${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "host", status: "accepted" },
      });
    } else if (afterStatus === "declined") {
      // Neutral by design: passing on an invitation isn't a rejection.
      await sendPush({
        recipientID: hostUserID,
        category: "stayUpdates",
        senderID: guestUserID,
        title: "Offer update",
        body: `${guestName} can't make it${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "host", status: "declined" },
      });
    }
  }
});

// ---------------------------------------------------------------------------
// exportUserData (callable)
// Returns all data held for the caller (profile, private data, listings, stay
// requests, messages, friend edges, reports) for GDPR/CCPA access, mirroring what
// onUserDeleted removes. Call: Functions.functions().httpsCallable("exportUserData")
// ---------------------------------------------------------------------------
export const exportUserData = onCall(callableOptions, async (request) => {
  const uid = requireFullMember(request);

  const [
    profileSnap,
    privateSnap,
    listingsSnap,
    guestRequestsSnap,
    hostRequestsSnap,
    messagesSnap,
    conversationsSnap,
    friendEdgesASnap,
    friendEdgesBSnap,
    reportsSnap,
    reviewsWrittenSnap,
    reviewsReceivedSnap,
    referencesWrittenSnap,
    referencesReceivedSnap,
  ] = await Promise.all([
    db.collection(Collections.users).doc(uid).get(),
    db.doc(privateProfilePath(uid)).get(),
    db.collection(Collections.homes).where("hostUserID", "==", uid).get(),
    db.collection(Collections.stayRequests).where("guestUserID", "==", uid).get(),
    db.collection(Collections.stayRequests).where("hostUserID", "==", uid).get(),
    db.collection(Collections.messages).where("participants", "array-contains", uid).get(),
    db.collection(Collections.conversations).where("participants", "array-contains", uid).get(),
    db.collection(Collections.friendEdges).where("userA", "==", uid).get(),
    db.collection(Collections.friendEdges).where("userB", "==", uid).get(),
    db.collection(Collections.reports).where("reporterUserID", "==", uid).get(),
    db.collection(Collections.reviews).where("authorUserID", "==", uid).get(),
    db.collection(Collections.reviews).where("subjectUserID", "==", uid).get(),
    db.collection(Collections.references).where("authorUserID", "==", uid).get(),
    db.collection(Collections.references).where("subjectUserID", "==", uid).get(),
  ]);

  const withID = (d: FirebaseFirestore.QueryDocumentSnapshot) => ({ id: d.id, ...d.data() });

  // Private feedback is exportable both written by and about the user, who is its only other reader.
  const privateFeedback = await Promise.all(
    [...reviewsWrittenSnap.docs, ...reviewsReceivedSnap.docs].map(async (doc) => {
      const snap = await doc.ref.collection(Subcollections.private).doc(Docs.feedback).get();
      return snap.exists ? { reviewID: doc.id, ...snap.data() } : null;
    })
  );

  return {
    profile: { ...(profileSnap.data() ?? {}), ...(privateSnap.data() ?? {}) },
    listings: listingsSnap.docs.map(withID),
    stayRequestsAsGuest: guestRequestsSnap.docs.map(withID),
    stayRequestsAsHost: hostRequestsSnap.docs.map(withID),
    messages: messagesSnap.docs.map(withID),
    conversations: conversationsSnap.docs.map(withID),
    friendEdges: [...friendEdgesASnap.docs, ...friendEdgesBSnap.docs].map(withID),
    reports: reportsSnap.docs.map(withID),
    reviewsWritten: reviewsWrittenSnap.docs.map(withID),
    reviewsReceived: reviewsReceivedSnap.docs.map(withID),
    referencesWritten: referencesWrittenSnap.docs.map(withID),
    referencesReceived: referencesReceivedSnap.docs.map(withID),
    privateFeedback: privateFeedback.filter((f) => f !== null),
  };
});

// ---------------------------------------------------------------------------
// suggestFriends (callable)
// "People you may know": friends-of-friends ranked by shared friends. Server-side
// because friendEdges are readable only by their two participants. Excludes anyone
// with an edge (friend or pending), blocked either way.
// Call: Functions.functions().httpsCallable("suggestFriends")
// ---------------------------------------------------------------------------
type FriendSuggestion = {
  userID: string;
  displayName: string;
  mutualCount: number;
  // Up to two of the caller's own friends connecting them to this candidate; never
  // the candidate's, so nothing is disclosed that the caller couldn't see.
  mutualNames: string[];
};

export const suggestFriends = onCall(callableOptions, async (request) => {
  const uid = requireFullMember(request);

  // Everyone the caller has any edge with, friend or pending, so suggestions are new people.
  const [myA, myB, myPrivateSnap] = await Promise.all([
    db.collection(Collections.friendEdges).where("userA", "==", uid).get(),
    db.collection(Collections.friendEdges).where("userB", "==", uid).get(),
    db.doc(privateProfilePath(uid)).get(),
  ]);
  const connected = new Set<string>([uid]);
  const myAcceptedFriends: string[] = [];
  for (const doc of myA.docs) {
    const d = doc.data();
    connected.add(d.userB);
    if (d.status === "accepted") myAcceptedFriends.push(d.userB);
  }
  for (const doc of myB.docs) {
    const d = doc.data();
    connected.add(d.userA);
    if (d.status === "accepted") myAcceptedFriends.push(d.userA);
  }
  for (const blocked of (myPrivateSnap.data()?.blockedUserIDs ?? []) as string[]) connected.add(blocked);

  // Tally which friends connect to each candidate, capping fan-out so a huge friend list can't cause thousands of reads.
  const FRIEND_CAP = 200;
  const connectors = new Map<string, string[]>();
  await Promise.all(
    myAcceptedFriends.slice(0, FRIEND_CAP).map(async (friendID) => {
      for (const candidate of await acceptedFriendsOf(friendID)) {
        if (connected.has(candidate)) continue;
        const existing = connectors.get(candidate);
        if (existing) existing.push(friendID);
        else connectors.set(candidate, [friendID]);
      }
    })
  );

  // Most mutual friends first.
  const ranked = [...connectors.entries()].sort((a, b) => b[1].length - a[1].length).slice(0, 10);

  // Cards say "Friends with Alice and Bob", so resolve names for the first two
  // connectors, deduplicated so each is fetched once.
  const NAMED_CONNECTORS = 2;
  const connectorIDs = [...new Set(ranked.flatMap(([, ids]) => ids.slice(0, NAMED_CONNECTORS)))];
  const connectorNames = new Map<string, string>();
  await Promise.all(
    connectorIDs.map(async (id) => {
      const snap = await db.collection(Collections.users).doc(id).get();
      const name = snap.data()?.displayName;
      if (typeof name === "string" && name.length > 0) connectorNames.set(id, name);
    })
  );

  // Resolve candidate names and drop anyone who blocked me.
  const resolved = await Promise.all(
    ranked.map(async ([candidate, mutualIDs]): Promise<FriendSuggestion | null> => {
      const [userSnap, candPrivateSnap] = await Promise.all([
        db.collection(Collections.users).doc(candidate).get(),
        db.doc(privateProfilePath(candidate)).get(),
      ]);
      if (!userSnap.exists) return null;
      const candBlocked: string[] = candPrivateSnap.data()?.blockedUserIDs ?? [];
      if (candBlocked.includes(uid)) return null;
      return {
        userID: candidate,
        displayName: userSnap.data()?.displayName ?? "FreeBNB User",
        mutualCount: mutualIDs.length,
        mutualNames: mutualIDs
          .slice(0, NAMED_CONNECTORS)
          .map((id) => connectorNames.get(id))
          .filter((name): name is string => name !== undefined),
      };
    })
  );

  return { suggestions: resolved.filter((s): s is FriendSuggestion => s !== null) };
});

// ---------------------------------------------------------------------------
// expireCompletedStays (scheduled)
// Address disclosure is granted by homes/{id}/accepted/{guestUID} and revoked on
// decline/cancel, but a stay that simply ended never revoked it. This daily sweep
// deletes the marker once checkOut has passed. It also closes the stay out
// (`accepted` → `completed`), unlocking reviews and trustStats; either party can
// do so early, so this backstops stays nobody touches.
//
// Re-booking safe: the marker is kept if the same guest has another accepted stay
// at the listing with a future checkout. Idempotent: handled requests carry
// accessRevokedAt, and deleting an absent marker is a no-op.
// ---------------------------------------------------------------------------
// How far back the sweep looks: a year of slack on a nightly job, so no plausible
// outage loses a revocation and the query doesn't grow with the app's history.
const EXPIRY_LOOKBACK_DAYS = 365;

export const expireCompletedStays = onSchedule(
  { schedule: "0 4 * * *", timeZone: "UTC" },
  async () => {
    const nowMs = Date.now();
    // Both statuses were granted: `accepted` (nobody closed it out) and `completed`
    // (a party did, but the grant only expires when the stay is over). Bounded by
    // checkOut rather than the whole collection, covering future-checkout stays that
    // veto a revocation and recently ended ones being revoked; partitioned in memory
    // below. A stay older than the window and never revoked stays granted, so widen
    // EXPIRY_LOOKBACK_DAYS for one run after a long outage or a first deploy.
    const cutoff = admin.firestore.Timestamp.fromMillis(
      nowMs - EXPIRY_LOOKBACK_DAYS * 24 * 60 * 60 * 1000
    );
    const snap = await db
      .collection(Collections.stayRequests)
      .where("status", "in", ["accepted", "completed"])
      .where("checkOut", ">=", cutoff)
      .get();

    type Expiring = {
      ref: FirebaseFirestore.DocumentReference;
      listingID: string;
      guestUserID: string;
      status: string;
    };
    const activeKeys = new Set<string>();
    const expired: Expiring[] = [];
    for (const doc of snap.docs) {
      const req = doc.data() as {
        listingID: string;
        guestUserID: string;
        status: string;
        checkOut: admin.firestore.Timestamp;
        accessRevokedAt?: admin.firestore.Timestamp;
      };
      const key = `${req.listingID}__${req.guestUserID}`;
      if (req.checkOut.toMillis() > nowMs) {
        // A future checkout keeps the address alive, unless the stay was closed out early.
        if (req.status === "accepted") activeKeys.add(key);
      } else if (!req.accessRevokedAt) {
        expired.push({ ref: doc.ref, listingID: req.listingID, guestUserID: req.guestUserID, status: req.status });
      }
    }

    // Drop any expired stay whose guest has a later accepted stay at the same listing
    // (it keeps the marker). 250 revocations per batch (two writes each) stays under 500 ops.
    const toRevoke = expired.filter((c) => !activeKeys.has(`${c.listingID}__${c.guestUserID}`));
    let revoked = 0;
    for (let i = 0; i < toRevoke.length; i += 250) {
      const batch = db.batch();
      for (const c of toRevoke.slice(i, i + 250)) {
        batch.delete(
          db.collection(Collections.homes).doc(c.listingID).collection(Subcollections.accepted).doc(c.guestUserID)
        );
        // Close the stay out in the same commit that withdraws the address, so it's never
        // left "accepted" unreviewable; `onStayRequestWritten` recomputes reputations.
        // An already-completed stay keeps its completedAt and only loses the address.
        batch.update(c.ref, {
          accessRevokedAt: admin.firestore.FieldValue.serverTimestamp(),
          ...(c.status === "accepted"
            ? {
              status: "completed",
              completedAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }
            : {}),
        });
        revoked++;
      }
      await batch.commit();
    }
    logger.info(`expireCompletedStays: revoked ${revoked} completed stay marker(s).`);
  }
);

// Message rate limiting is enforced by firestore.rules: every message create must
// advance the sender's rateLimits/{uid} counter (30 messages per 60s window).

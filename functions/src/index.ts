import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
// The auth `onDelete` background trigger has no v2 equivalent (v2 offers only the
// `beforeUserCreated`/`beforeUserSignedIn` blocking triggers, not a post-delete
// hook), so that one function stays on the v1 API surface. v1 and v2 functions
// coexist in the same codebase and deploy together (A4).
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

// Firestore caps a WriteBatch at 500 operations, and holding an unbounded result
// set in memory is its own scaling ceiling (A9).
const PAGE_SIZE = 500;

// Deletes every document a query matches, one bounded page at a time. Because a
// deleted document no longer matches, each `get()` returns only outstanding work,
// so a retry after a mid-run failure resumes where it left off instead of
// rescanning from the top (A9). The caller must pass a query with no `limit`.
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

// Deletes every Storage object under `prefix` from the default bucket. Used to
// cascade a user's listing photos (listings/{uid}/**) on account deletion:
// the Firestore listing survives as history, but the binary assets are personal
// data and a cost leak (S7). A missing bucket or empty prefix is a no-op.
async function deleteStoragePrefix(prefix: string): Promise<void> {
  await admin.storage().bucket().deleteFiles({ prefix });
}

// ---------------------------------------------------------------------------
// Push notifications
// Per-category preferences live in the recipient's private profile as a
// `notificationPrefs` map. A category counts as enabled unless the map stores
// `false` for it, so an absent map or key means opted-in — clients only persist
// the categories a user turns off (feature 37). The client mirror is
// NotificationCategory in NotificationPreferences.swift; keep the keys in sync.
// ---------------------------------------------------------------------------
type NotificationCategory = "messages" | "stayRequests" | "stayUpdates";

function notificationEnabled(
  privateData: FirebaseFirestore.DocumentData | undefined,
  category: NotificationCategory
): boolean {
  const prefs = privateData?.notificationPrefs as Record<string, unknown> | undefined;
  return prefs?.[category] !== false;
}

// Sends one push to `recipientID` for `category`, gated by their notification
// preference, block list, and having a registered FCM token — any failed gate
// is a silent no-op. `senderID`, when given, suppresses the push if the
// recipient has blocked that user. A missing/unreadable private profile is
// treated as "opted in with no token", so it simply sends nothing.
async function sendStayPush(opts: {
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
// scheduledFirestoreBackup
// Exports all Firestore collections to GCS once a day at 03:00 UTC.
//
// One-time setup required:
//   1. Create a GCS bucket named "${PROJECT_ID}-backups" in the same region.
//   2. Grant the App Engine default service account
//      (${PROJECT_ID}@appspot.gserviceaccount.com) the roles:
//        - storage.admin  (on the backup bucket)
//        - datastore.importExportAdmin  (on the project)
//   3. Deploy this function: firebase deploy --only functions
//
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
// Maintains the denormalized `conversations/{id}` summary and pushes to the
// recipient. The summary doc (last message, per-user unread counts, mutes) is
// the source of truth the client's conversation list and unread badge read
// from, so a chatty thread no longer evicts other conversations from the list
// (L2), and read/mute state lives server-side and syncs across devices (L4).
// ---------------------------------------------------------------------------

// Counts the user's non-muted conversations that still hold unread messages —
// the value both the app's tab badge and the APNs badge display. Pages over the
// recipient's conversations so the fan-out stays bounded no matter how many
// threads they have (A9).
async function unreadConversationCount(userID: string): Promise<number> {
  const base = db
    .collection(Collections.conversations)
    .where("participants", "array-contains", userID)
    .orderBy(admin.firestore.FieldPath.documentId());

  let count = 0;
  let cursor: string | undefined;
  for (;;) {
    let query = base.limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      const data = doc.data();
      const muted: string[] = data.mutedBy ?? [];
      if (muted.includes(userID)) continue;
      const unread: number = data.unreadCounts?.[userID] ?? 0;
      if (unread > 0) count++;
    }
    if (snap.size < PAGE_SIZE) break;
    cursor = snap.docs[snap.docs.length - 1].id;
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

  // Upsert the conversation summary. The conversationID mirrors the client's
  // MessageStore.conversationID: sorted participants joined by "_". merge keeps
  // the other participant's unread count and any mutedBy list intact; the
  // sender is caught up (0) and the recipient's counter advances — increment()
  // treats a missing counter as 0, so the first message lands the count at 1.
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

  // The recipient's token and block list live in their owner-only private
  // subdocument; the sender's display name is on the public user doc; the
  // recipient's mute lives on the conversation doc we just wrote.
  const [recipientPrivate, senderDoc, convSnap] = await Promise.all([
    db.doc(privateProfilePath(recipientID)).get(),
    db.collection(Collections.users).doc(senderID).get(),
    convRef.get(),
  ]);

  // A muted conversation gets no push and never counts toward the badge.
  const mutedBy: string[] = convSnap.data()?.mutedBy ?? [];
  if (mutedBy.includes(recipientID)) return;

  const recipientData = recipientPrivate.data();

  // Respect the recipient's per-category preference: a muted "messages"
  // category silences the push (the unread count still advanced above).
  if (!notificationEnabled(recipientData, "messages")) return;

  // Never push a notification from someone the recipient has blocked.
  const blocked: string[] = recipientData?.blockedUserIDs ?? [];
  if (blocked.includes(senderID)) return;

  const fcmToken: string | undefined = recipientData?.fcmToken;
  if (!fcmToken) return;

  const senderName: string = senderDoc.data()?.displayName ?? "FreeBNB";

  // Badge the actual number of unread conversations, not a hardcoded 1 (L4).
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
// `homes.allowedViewerIDs` is the denormalized read ACL that firestore.rules
// enforces listing visibility with, because rules cannot join to `friendEdges`
// at query time. Every listing gets the same audience:
//
//   host + accepted friends
//
// There are no wider tiers. Friends-of-friends never see a listing; they see
// its host as a friend *suggestion* (see suggestFriends below), and gain access
// only once the host accepts them. The client stamps the same first-degree
// array on save (so a listing is correct the instant it is written), and
// `onHomeWrittenACL` repairs any drift immediately afterwards.
//
// Everything below rebuilds the array from the graph rather than applying a
// delta: a full rebuild is idempotent, which is what makes the retries safe.
// A legacy `visibility` field may still sit on old documents; it is ignored
// here and stripped by scripts/migrate_friends_only.js.
// ---------------------------------------------------------------------------
type FriendEdgeData = { userA: string; userB: string; status?: string };

// The rules cap `allowedViewerIDs` at 1000 entries, and the whole array is
// downloaded with every feed document, so a very well-connected host's
// friend list is truncated rather than allowed to bloat the feed.
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

  // Every listing carries the same ACL. The host is always in it: the rules
  // refuse a listing that locks its own host out.
  const desired = [...new Set([hostID, ...friends])].slice(0, ACL_CAP);

  // Updating one listing reads one document, not the host's whole catalogue.
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
// A listing's audience is exactly its host's accepted friends, so an edge
// changing accepted-ness moves only the two endpoints' own ACLs: accepting
// admits each user to the other's listings, unfriending revokes both. This is
// the write that makes "accepting a friend request shares your listings with
// them" true.
// ---------------------------------------------------------------------------
export const onFriendEdgeWritten = onDocumentWritten(friendEdgeDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? (change.before.data() as FriendEdgeData) : undefined;
  const after = change?.after.exists ? (change.after.data() as FriendEdgeData) : undefined;

  const wasFriends = before?.status === "accepted";
  const isFriends = after?.status === "accepted";
  if (wasFriends === isFriends) return;

  const edge = after ?? before;
  if (!edge?.userA || !edge?.userB) return;

  await Promise.all([edge.userA, edge.userB].map((hostID) => rebuildListingACLs(hostID)));
});

// ---------------------------------------------------------------------------
// onHomeWrittenACL
// The client stamps the host's accepted friends on save; this repairs any
// listing whose ACL drifted (a stale client, a partial write). It is a
// separate trigger from onHomeDeleted so each stays about one thing.
// ---------------------------------------------------------------------------
export const onHomeWrittenACL = onDocumentWritten(homeDocPattern, async (event) => {
  const after = event.data?.after.exists ? event.data.after.data() : undefined;
  if (!after) return; // deletes are onHomeDeleted's business
  const hostUserID: string | undefined = after.hostUserID;
  if (!hostUserID) return;

  await rebuildListingACLs(hostUserID, event.params.homeID);
});

// ---------------------------------------------------------------------------
// Trust stats (feature 2)
//
// The reputation numbers on `users/{uid}.trustStats`. They are recomputed from
// scratch whenever a stay or a review moves, never incremented in place: an
// increment that runs twice on a retry inflates someone's record permanently,
// and these are exactly the numbers a stranger decides to sleep in a house on.
//
// firestore.rules pins `trustStats` against every client write, so this function
// (writing with admin credentials) is the only thing that can move them.
// ---------------------------------------------------------------------------

/** Below this many received requests, a response rate is noise. Mirrors TrustStats.minimumResponses. */
const MIN_RESPONSES_FOR_RATE = 3;

type TrustStats = {
  staysHosted: number;
  staysTaken: number;
  reviewCount: number;
  averageRating: number | null;
  responseRate: number | null;
  respondedCount: number;
  receivedCount: number;
};

async function recomputeTrustStats(userID: string): Promise<void> {
  const [asHost, asGuest, aboutThem] = await Promise.all([
    db.collection(Collections.stayRequests).where("hostUserID", "==", userID).get(),
    db.collection(Collections.stayRequests).where("guestUserID", "==", userID).get(),
    db.collection(Collections.reviews).where("subjectUserID", "==", userID).get(),
  ]);

  let staysHosted = 0;
  let receivedCount = 0;
  let respondedCount = 0;
  for (const doc of asHost.docs) {
    const status: string = doc.data().status;
    if (status === "completed") staysHosted++;
    // A guest-cancelled request was withdrawn, not ignored, so it is neither
    // asked nor answered. Everything else landed in the host's inbox.
    if (status === "cancelled") continue;
    receivedCount++;
    if (status !== "pending") respondedCount++;
  }

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
    responseRate: receivedCount >= MIN_RESPONSES_FOR_RATE ? respondedCount / receivedCount : null,
    respondedCount,
    receivedCount,
  };

  // Never resurrect a deleted account as a stats-only document: the public user
  // doc must always carry a displayName for the client to decode it.
  const userRef = db.collection(Collections.users).doc(userID);
  if (!(await userRef.get()).exists) return;
  await userRef.set({ trustStats: stats }, { merge: true });
}

// ---------------------------------------------------------------------------
// onReviewWritten
// A review changes the reviewed person's rating, so recompute their stats.
// ---------------------------------------------------------------------------
export const onReviewWritten = onDocumentWritten(reviewDocPattern, async (event) => {
  const change = event.data;
  const subjectUserID: string | undefined =
    (change?.after.exists ? change.after.data() : change?.before.data())?.subjectUserID;
  if (!subjectUserID) return;
  await recomputeTrustStats(subjectUserID);
});

// ---------------------------------------------------------------------------
// Keyword moderation (feature 6)
// Nothing is blocked or hidden: a hit files a report into the same triage queue
// a human report lands in, tagged `source: "auto"`. A false positive costs a
// moderator one click; a false negative that silently ate a real message would
// cost a user their conversation.
//
// The report id is derived from the target, so a retry (or an edit that trips
// the same terms again) overwrites the open report rather than spamming the
// queue with duplicates.
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
  // The free-text fields a host controls. Structured fields are enum-validated
  // by the rules and cannot carry prose.
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
// mutualFriends (callable)
// "You and Priya have 3 friends in common" (feature 2). Server-side because
// `friendEdges` documents are readable only by the two users they connect, so a
// client cannot see anyone else's edges to intersect them.
// Call from the app: httpsCallable("mutualFriends").call(["userID": id])
// ---------------------------------------------------------------------------
export const mutualFriends = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

  const otherID: unknown = request.data?.userID;
  if (typeof otherID !== "string" || otherID.length === 0) {
    throw new HttpsError("invalid-argument", "userID is required.");
  }
  if (otherID === uid) return { count: 0, names: [] };

  const [mine, theirs] = await Promise.all([acceptedFriendsOf(uid), acceptedFriendsOf(otherID)]);
  const mineSet = new Set(mine);
  const shared = [...new Set(theirs.filter((id) => mineSet.has(id)))];

  // Only a couple of names are ever rendered ("Priya, Sam and 3 others"), so
  // resolve only those rather than every mutual friend.
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
// Server-side cascade when a Firebase Auth user is removed.
// The iOS client soft-deletes listings before calling user.delete(), so this
// is a safety net for deletions that bypass the client (e.g. console, admin).
//
// Stays on the v1 API: v2 has no post-delete auth trigger (see the import note).
// ---------------------------------------------------------------------------
export const onUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;

  // Soft-delete the user's listings (kept for history), chunked under the
  // 500-op batch cap for prolific hosts.
  const listingsSnap = await db.collection(Collections.homes).where("hostUserID", "==", uid).get();
  for (let i = 0; i < listingsSnap.docs.length; i += PAGE_SIZE) {
    const batch = db.batch();
    const now = admin.firestore.FieldValue.serverTimestamp();
    for (const doc of listingsSnap.docs.slice(i, i + PAGE_SIZE)) {
      batch.update(doc.ref, { deletedAt: now });
    }
    await batch.commit();
  }

  // The listing document survives as history, but the street address must not.
  // Drop each listing's private location and the markers granting guests access
  // to it, and revoke the addresses this user held as a guest elsewhere.
  await Promise.all([
    ...listingsSnap.docs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.private))),
    ...listingsSnap.docs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.accepted))),
    deleteQueryInChunks(db.collectionGroup(Subcollections.accepted).where("guestUserID", "==", uid)),
    // Listing photos live in Storage, not Firestore, so the document cascade
    // above never reaches them. Drop the whole listings/{uid}/ tree (S7).
    deleteStoragePrefix(listingPhotosPrefix(uid)),
  ]);

  // Reviews and references naming this user go too — both the ones they wrote
  // and the ones written about them, since a review of a deleted account names a
  // person who no longer exists and can no longer answer it. Each review carries
  // a private/feedback subdocument that Firestore would otherwise strand.
  const reviewAndReferenceDocs = await Promise.all([
    db.collection(Collections.reviews).where("authorUserID", "==", uid).get(),
    db.collection(Collections.reviews).where("subjectUserID", "==", uid).get(),
    db.collection(Collections.references).where("authorUserID", "==", uid).get(),
    db.collection(Collections.references).where("subjectUserID", "==", uid).get(),
  ]);
  const reviewDocs = [...reviewAndReferenceDocs[0].docs, ...reviewAndReferenceDocs[1].docs];
  await Promise.all(reviewDocs.map((doc) => deleteQueryInChunks(doc.ref.collection(Subcollections.private))));

  // Everyone whose reputation was computed partly from this user's stays or
  // reviews. Collected before the deletions, recomputed after them.
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

  // Hard-cascade the user's own messages, stay requests (as guest and host),
  // friend edges, and submitted reports so no personal data is left behind.
  // Only messages the user authored are removed, preserving the other party's
  // side of any shared conversation.
  await Promise.all([
    deleteQueryInChunks(db.collection(Collections.messages).where("senderUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.stayRequests).where("guestUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.stayRequests).where("hostUserID", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.friendEdges).where("userA", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.friendEdges).where("userB", "==", uid)),
    deleteQueryInChunks(db.collection(Collections.reports).where("reporterUserID", "==", uid)),
    // Conversation summaries carry the user's name in lastMessage and their
    // unread/mute state, so drop every summary they took part in. The other
    // party's own messages survive; their next message rebuilds the summary.
    deleteQueryInChunks(db.collection(Collections.conversations).where("participants", "array-contains", uid)),
  ]);

  // Finally remove the private subdocument and the public user document.
  await db.doc(privateProfilePath(uid)).delete();
  await db.collection(Collections.users).doc(uid).delete();

  // Stay-request deletions don't fire `onStayRequestWritten` (it ignores deletes),
  // so the counterparties' stay counts and response rates would otherwise keep
  // counting a person who no longer exists. `recomputeTrustStats` skips anyone
  // whose own user document is already gone.
  await Promise.all([...counterparties].map((id) => recomputeTrustStats(id)));
});

// ---------------------------------------------------------------------------
// onHomeDeleted
// `onUserDeleted` cascades a whole account's photos, but deleting a single
// listing reached neither its Storage objects nor its subcollections, so both
// outlived the listing (S7). Storage photos are the sharper leak of the two:
// storage.rules lets any signed-in user read `listings/{uid}/{homeID}/**`, so a
// delisted home kept serving its photos to the whole app, and kept billing for
// them.
//
// A listing goes away two ways, and they are not equivalent:
//   - Hard delete (the document is removed). firestore.rules permits this, and
//     Firestore does not delete a document's subcollections with it, so
//     `private/location` and the `accepted/` markers are stranded. Nothing can
//     read them once the parent is gone (`isListingHost` fails closed), but the
//     street address is still sitting there, so drop it along with the photos.
//   - Soft delete (`deletedAt` goes from unset to set). This is the client's
//     delete path. Photos go, but `private/location` and `accepted/` stay: a
//     guest may be mid-stay and still need the address, and `expireCompletedStays`
//     already owns revoking those markers once the stay is over.
//
// Every branch is idempotent, so both the retry on a thrown error and the
// duplicate fire when `onUserDeleted` soft-deletes a host's listings are safe.
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
  // A listing with no host has no photo prefix to target; nothing to do.
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
// Owns stay acceptance so the double-booking guard is race-free (L1). The old
// client path read accepted requests, checked overlap in code, then wrote —
// two hosts (or one host on two devices) accepting concurrently could both pass
// the check. This runs the read-check-write inside one Firestore transaction,
// which the admin SDK (unlike the iOS client) can do over a query. It also owns
// the address-disclosure marker, so acceptance is atomic end to end.
// Call from the app: httpsCallable("acceptStayRequest").call(["requestID": id])
// ---------------------------------------------------------------------------
export const acceptStayRequest = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

  const requestID: unknown = request.data?.requestID;
  const hostNote: unknown = request.data?.hostNote;
  if (typeof requestID !== "string" || requestID.length === 0) {
    throw new HttpsError("invalid-argument", "requestID is required.");
  }
  if (hostNote !== undefined && typeof hostNote !== "string") {
    throw new HttpsError("invalid-argument", "hostNote must be a string.");
  }
  // Admin writes bypass firestore.rules, so the rules' 2000-char cap on
  // hostNote has to be re-enforced here or this callable becomes the one path
  // that can stuff an unbounded string onto the document.
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
    // Only the host of this request may accept it, and only while it is pending.
    if (req.hostUserID !== uid) {
      throw new HttpsError("permission-denied", "Only the host can accept this request.");
    }
    if (req.status !== "pending") {
      throw new HttpsError("failed-precondition", "Only a pending request can be accepted.");
    }

    // The listing must still exist and still be live. Accepting a request for a
    // deleted listing would disclose a street address for a home that is no
    // longer offered, via a marker under a document nothing cleans up.
    const listingSnap = await t.get(db.collection(Collections.homes).doc(req.listingID));
    if (!listingSnap.exists || listingSnap.data()?.deletedAt) {
      throw new HttpsError("failed-precondition", "This listing is no longer available.");
    }

    // All reads must precede all writes in a transaction. Re-read the accepted
    // requests for this listing inside the txn so a concurrent accept that
    // committed first is seen here and blocks this one.
    const accepted = await t.get(
      db.collection(Collections.stayRequests)
        .where("listingID", "==", req.listingID)
        .where("status", "==", "accepted")
    );
    const inMs = req.checkIn.toMillis();
    const outMs = req.checkOut.toMillis();
    for (const doc of accepted.docs) {
      if (doc.id === requestID) continue;
      const other = doc.data() as { checkIn: admin.firestore.Timestamp; checkOut: admin.firestore.Timestamp };
      // Half-open interval overlap: [checkIn, checkOut).
      if (other.checkIn.toMillis() < outMs && inMs < other.checkOut.toMillis()) {
        // "aborted" (not "failed-precondition") so the client can distinguish a
        // double-booking from the not-pending case and show the right message.
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
// onStayRequestWritten
// Stay-lifecycle push notifications with a deep link into the Stays tab
// (feature 36): the host hears about a brand-new request, and the guest hears
// when their pending request is accepted or declined. The chatty courtesy notes
// the app also posts to the thread ride the separate "messages" category; these
// use "stayRequests"/"stayUpdates" so each can be muted on its own (feature 37).
// ---------------------------------------------------------------------------
export const onStayRequestWritten = onDocumentWritten(stayRequestDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? change.before.data() : undefined;
  const after = change?.after.exists ? change.after.data() : undefined;
  if (!after) return; // a deletion has no one to notify

  const requestID = event.params.requestID;
  const listingCity: string = after.listingCity ?? "";
  const listingTitle: string = after.listingTitle ?? "";
  const guestUserID: string = after.guestUserID;
  const hostUserID: string = after.hostUserID;
  const beforeStatus: string | undefined = before?.status;
  const afterStatus: string = after.status;
  // Name the specific home when the host titled it ("for Guest room by the Rose
  // Bowl"), since one host can list several; otherwise fall back to the city.
  const placeSuffix = listingTitle
    ? ` for ${listingTitle}`
    : listingCity
    ? ` in ${listingCity}`
    : "";

  // Stays hosted, stays taken, and the host's response rate all move with a
  // status change, so both parties' reputations are recomputed before anything
  // else. A create counts too: it is the request that lands in the host's inbox
  // and starts the response-rate clock.
  if (beforeStatus !== afterStatus) {
    await Promise.all([recomputeTrustStats(hostUserID), recomputeTrustStats(guestUserID)]);
  }

  // A freshly created pending request → notify the host.
  if (!before && afterStatus === "pending") {
    const guestName =
      (await db.collection(Collections.users).doc(guestUserID).get()).data()?.displayName ?? "Someone";
    await sendStayPush({
      recipientID: hostUserID,
      category: "stayRequests",
      senderID: guestUserID,
      title: "New stay request",
      body: `${guestName} asked to stay${placeSuffix}.`,
      data: { type: "stay_request", requestID, role: "host" },
    });
    return;
  }

  // The host resolved a pending request → notify the guest. "cancelled" is a
  // guest-initiated status, so it never notifies here.
  if (beforeStatus === "pending" && afterStatus !== "pending") {
    const hostName: string = after.listingHostName ?? "The host";
    if (afterStatus === "accepted") {
      await sendStayPush({
        recipientID: guestUserID,
        category: "stayUpdates",
        senderID: hostUserID,
        title: "Stay accepted 🎉",
        body: `${hostName} accepted your request${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "guest", status: "accepted" },
      });
    } else if (afterStatus === "declined") {
      await sendStayPush({
        recipientID: guestUserID,
        category: "stayUpdates",
        senderID: hostUserID,
        title: "Stay request update",
        body: `${hostName} couldn't host your request${placeSuffix}.`,
        data: { type: "stay_update", requestID, role: "guest", status: "declined" },
      });
    }
  }
});

// ---------------------------------------------------------------------------
// exportUserData (callable)
// Returns all data we hold for the calling user: public profile, private
// profile data, listings, stay requests, full message content, friend edges,
// and submitted reports. Fulfills GDPR/CCPA right-to-access, and mirrors what
// onUserDeleted removes so the export is complete relative to what is stored.
// Call from the app: Functions.functions().httpsCallable("exportUserData")
// ---------------------------------------------------------------------------
export const exportUserData = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

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

  // The private feedback a user wrote is theirs to export; the private feedback
  // written *about* them is too, since they are its only other reader.
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
// "People you may know": friends-of-friends ranked by how many of the caller's
// friends they share (feature 31). Runs server-side because friendEdges are
// readable only by their two participants — a client cannot traverse the graph
// past its own edges. Excludes anyone the caller already has an edge with
// (friend or pending), has blocked, or who has blocked the caller.
// Call from the app: Functions.functions().httpsCallable("suggestFriends")
// ---------------------------------------------------------------------------
type FriendSuggestion = {
  userID: string;
  displayName: string;
  mutualCount: number;
  // Up to two of the caller's own friends who connect them to this candidate,
  // e.g. ["Alice", "Bob"]. Only the caller's existing friends are named — never
  // the candidate's — so nothing is disclosed the caller couldn't already see.
  mutualNames: string[];
};

export const suggestFriends = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

  // Everyone the caller already has any edge with — friends and pending both —
  // so a suggestion is never someone they're already connected to or awaiting.
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

  // Tally which of my friends each candidate is connected to. Cap the fan-out
  // so a user with an enormous friend list can't turn one call into thousands of
  // reads.
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

  // The cards say "Friends with Alice and Bob", so resolve display names for
  // the first two connectors of each candidate. These are the caller's own
  // friends, deduplicated across candidates so each name is fetched once.
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
// Progressive address disclosure is granted by homes/{id}/accepted/{guestUID}
// and revoked on decline/cancel (client) — but a stay that simply runs its
// course and ends never revoked it, so a past guest kept the host's street
// forever (S2). This daily sweep deletes the marker once a stay's checkOut has
// passed, expiring the guest's access.
//
// It also closes the stay out: `accepted` → `completed`, which is what unlocks
// both parties' reviews and what trustStats counts (feature 4). Either party can
// reach the same state early by tapping "Mark complete" once the stay has begun;
// this is the backstop for the stays nobody touches.
//
// Re-booking safe: if the same guest still has another accepted stay at the same
// listing whose checkout is in the future, the marker is kept. Idempotent: a
// request already handled carries accessRevokedAt and is skipped, and deleting an
// absent marker is a no-op.
// ---------------------------------------------------------------------------
export const expireCompletedStays = onSchedule(
  { schedule: "0 4 * * *", timeZone: "UTC" },
  async () => {
    const nowMs = Date.now();
    // Both statuses mean the stay was granted: `accepted` is one nobody closed
    // out, `completed` is one a party already marked done (feature 4) but whose
    // address grant only expires when the stay is actually over. A single `in`
    // filter on one field needs no composite index; partition in memory so a
    // guest's still-running stay can veto the revocation.
    const snap = await db
      .collection(Collections.stayRequests)
      .where("status", "in", ["accepted", "completed"])
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
        // A stay whose checkout is still ahead keeps the address alive — but only
        // if it hasn't been closed out. Marking a stay complete early is a
        // statement that it's over.
        if (req.status === "accepted") activeKeys.add(key);
      } else if (!req.accessRevokedAt) {
        expired.push({ ref: doc.ref, listingID: req.listingID, guestUserID: req.guestUserID, status: req.status });
      }
    }

    // Drop any expired stay whose guest still has a future accepted stay at the
    // same listing — that later stay keeps the marker alive. 250 revocations per
    // batch (two writes each) stays under the 500-op cap.
    const toRevoke = expired.filter((c) => !activeKeys.has(`${c.listingID}__${c.guestUserID}`));
    let revoked = 0;
    for (let i = 0; i < toRevoke.length; i += 250) {
      const batch = db.batch();
      for (const c of toRevoke.slice(i, i + 250)) {
        batch.delete(
          db.collection(Collections.homes).doc(c.listingID).collection(Subcollections.accepted).doc(c.guestUserID)
        );
        // Close the stay out in the same commit that withdraws the address, so a
        // stay is never left "accepted" with no way for either party to review it.
        // `onStayRequestWritten` sees the status move and recomputes both
        // reputations. A stay a party already completed keeps its original
        // completedAt and only loses the address.
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

// Message rate limiting is enforced in the write path by firestore.rules: every
// message create must advance the sender's rateLimits/{uid} counter, which the
// rules cap at 30 messages per 60s window. The former checkMessageRate callable
// (an advisory, ignored-result pre-check) has been removed in favour of it.

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
  Subcollections,
  friendEdgeDocPattern,
  listingPhotosPrefix,
  messageDocPattern,
  privateProfilePath,
} from "./paths";

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
// onFriendEdgeWritten
// Keeps `homes.allowedViewerIDs` — the denormalized read ACL that Firestore
// rules enforce friends-only visibility with — in sync with the friend graph.
//
// Only the accepted/not-accepted transition matters: a pending edge grants
// nothing, and an accepted edge that is deleted revokes access. The client
// stamps the array on every listing save, so this trigger only has to carry
// the delta between saves.
// ---------------------------------------------------------------------------
type FriendEdgeData = { userA: string; userB: string; status?: string };

// Adds or removes `viewerID` from every listing hosted by `hostID`, one bounded
// page at a time. The id cursor keeps the fan-out from loading a prolific host's
// entire catalogue into memory, and because arrayUnion/arrayRemove are
// idempotent, a retry that re-commits a page is harmless (A9).
async function setViewerOnListings(
  hostID: string,
  viewerID: string,
  grant: boolean
): Promise<void> {
  const change = grant
    ? admin.firestore.FieldValue.arrayUnion(viewerID)
    : admin.firestore.FieldValue.arrayRemove(viewerID);
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
    for (const doc of snap.docs) batch.update(doc.ref, { allowedViewerIDs: change });
    await batch.commit();
    if (snap.size < PAGE_SIZE) return;
    cursor = snap.docs[snap.docs.length - 1].id;
  }
}

export const onFriendEdgeWritten = onDocumentWritten(friendEdgeDocPattern, async (event) => {
  const change = event.data;
  const before = change?.before.exists ? (change.before.data() as FriendEdgeData) : undefined;
  const after = change?.after.exists ? (change.after.data() as FriendEdgeData) : undefined;

  const wasFriends = before?.status === "accepted";
  const isFriends = after?.status === "accepted";
  if (wasFriends === isFriends) return;

  const edge = after ?? before;
  if (!edge?.userA || !edge?.userB) return;

  // Friendship is symmetric: each user becomes a viewer of the other's homes.
  await Promise.all([
    setViewerOnListings(edge.userA, edge.userB, isFriends),
    setViewerOnListings(edge.userB, edge.userA, isFriends),
  ]);
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
  ]);

  const withID = (d: FirebaseFirestore.QueryDocumentSnapshot) => ({ id: d.id, ...d.data() });

  return {
    profile: { ...(profileSnap.data() ?? {}), ...(privateSnap.data() ?? {}) },
    listings: listingsSnap.docs.map(withID),
    stayRequestsAsGuest: guestRequestsSnap.docs.map(withID),
    stayRequestsAsHost: hostRequestsSnap.docs.map(withID),
    messages: messagesSnap.docs.map(withID),
    conversations: conversationsSnap.docs.map(withID),
    friendEdges: [...friendEdgesASnap.docs, ...friendEdgesBSnap.docs].map(withID),
    reports: reportsSnap.docs.map(withID),
  };
});

// ---------------------------------------------------------------------------
// expireCompletedStays (scheduled)
// Progressive address disclosure is granted by homes/{id}/accepted/{guestUID}
// and revoked on decline/cancel (client) — but a stay that simply runs its
// course and ends never revoked it, so a past guest kept the host's street
// forever (S2). This daily sweep deletes the marker once a stay's checkOut has
// passed, expiring the guest's access. The stay stays "accepted" as history;
// only the address grant is withdrawn.
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
    // One query on an auto-indexed equality; partition in memory so no composite
    // index is needed and a guest's still-active stay can veto the revocation.
    const snap = await db.collection(Collections.stayRequests).where("status", "==", "accepted").get();

    const activeKeys = new Set<string>();
    const completed: { ref: FirebaseFirestore.DocumentReference; listingID: string; guestUserID: string }[] = [];
    for (const doc of snap.docs) {
      const req = doc.data() as {
        listingID: string;
        guestUserID: string;
        checkOut: admin.firestore.Timestamp;
        accessRevokedAt?: admin.firestore.Timestamp;
      };
      const key = `${req.listingID}__${req.guestUserID}`;
      if (req.checkOut.toMillis() > nowMs) {
        activeKeys.add(key);
      } else if (!req.accessRevokedAt) {
        completed.push({ ref: doc.ref, listingID: req.listingID, guestUserID: req.guestUserID });
      }
    }

    // Drop any completed stay whose guest still has a future accepted stay at the
    // same listing — that later stay keeps the marker alive. 250 revocations per
    // batch (two writes each) stays under the 500-op cap.
    const toRevoke = completed.filter((c) => !activeKeys.has(`${c.listingID}__${c.guestUserID}`));
    let revoked = 0;
    for (let i = 0; i < toRevoke.length; i += 250) {
      const batch = db.batch();
      for (const c of toRevoke.slice(i, i + 250)) {
        batch.delete(
          db.collection(Collections.homes).doc(c.listingID).collection(Subcollections.accepted).doc(c.guestUserID)
        );
        batch.update(c.ref, { accessRevokedAt: admin.firestore.FieldValue.serverTimestamp() });
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

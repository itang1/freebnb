import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

admin.initializeApp();

const db = admin.firestore();

// Firestore caps a WriteBatch at 500 operations. Deletes every document a
// query matches, committing in chunks so large result sets don't exceed it.
async function deleteQueryInChunks(query: FirebaseFirestore.Query): Promise<void> {
  const snap = await query.get();
  const refs = snap.docs.map((d) => d.ref);
  for (let i = 0; i < refs.length; i += 500) {
    const batch = db.batch();
    for (const ref of refs.slice(i, i + 500)) batch.delete(ref);
    await batch.commit();
  }
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
export const scheduledFirestoreBackup = functions.pubsub
  .schedule("0 3 * * *")
  .timeZone("UTC")
  .onRun(async () => {
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
    functions.logger.info("Firestore backup started", { operation: op.name, outputUri });
  });

// ---------------------------------------------------------------------------
// onMessageCreated
// Sends a push notification to the recipient of a new message.
// ---------------------------------------------------------------------------
export const onMessageCreated = functions.firestore
  .document("messages/{messageID}")
  .onCreate(async (snap) => {
    const msg = snap.data() as {
      senderUserID: string;
      participants: string[];
      text: string;
    };

    const recipientID = msg.participants.find((uid) => uid !== msg.senderUserID);
    if (!recipientID) return;

    // The recipient's token and block list live in their owner-only private
    // subdocument; the sender's display name is on the public user doc.
    const [recipientPrivate, senderDoc] = await Promise.all([
      db.doc(`users/${recipientID}/private/profile`).get(),
      db.collection("users").doc(msg.senderUserID).get(),
    ]);

    const recipientData = recipientPrivate.data();

    // Never push a notification from someone the recipient has blocked.
    const blocked: string[] = recipientData?.blockedUserIDs ?? [];
    if (blocked.includes(msg.senderUserID)) return;

    const fcmToken: string | undefined = recipientData?.fcmToken;
    if (!fcmToken) return;

    const senderName: string = senderDoc.data()?.displayName ?? "FreeBNB";

    await admin.messaging().send({
      token: fcmToken,
      notification: {
        title: senderName,
        body: msg.text.length > 120 ? msg.text.slice(0, 120) + "…" : msg.text,
      },
      apns: {
        payload: { aps: { sound: "default", badge: 1 } },
      },
      data: { type: "message", senderUserID: msg.senderUserID },
    });
  });

// ---------------------------------------------------------------------------
// onUserDeleted
// Server-side cascade when a Firebase Auth user is removed.
// The iOS client soft-deletes listings before calling user.delete(), so this
// is a safety net for deletions that bypass the client (e.g. console, admin).
// ---------------------------------------------------------------------------
export const onUserDeleted = functions.auth.user().onDelete(async (user) => {
  const uid = user.uid;

  // Soft-delete the user's listings (kept for history), chunked under the
  // 500-op batch cap for prolific hosts.
  const listingsSnap = await db.collection("homes").where("hostUserID", "==", uid).get();
  for (let i = 0; i < listingsSnap.docs.length; i += 500) {
    const batch = db.batch();
    const now = admin.firestore.FieldValue.serverTimestamp();
    for (const doc of listingsSnap.docs.slice(i, i + 500)) {
      batch.update(doc.ref, { deletedAt: now });
    }
    await batch.commit();
  }

  // Hard-cascade the user's own messages, stay requests (as guest and host),
  // friend edges, and submitted reports so no personal data is left behind.
  // Only messages the user authored are removed, preserving the other party's
  // side of any shared conversation.
  await Promise.all([
    deleteQueryInChunks(db.collection("messages").where("senderUserID", "==", uid)),
    deleteQueryInChunks(db.collection("stayRequests").where("guestUserID", "==", uid)),
    deleteQueryInChunks(db.collection("stayRequests").where("hostUserID", "==", uid)),
    deleteQueryInChunks(db.collection("friendEdges").where("userA", "==", uid)),
    deleteQueryInChunks(db.collection("friendEdges").where("userB", "==", uid)),
    deleteQueryInChunks(db.collection("reports").where("reporterUserID", "==", uid)),
  ]);

  // Finally remove the private subdocument and the public user document.
  await db.doc(`users/${uid}/private/profile`).delete();
  await db.collection("users").doc(uid).delete();
});

// ---------------------------------------------------------------------------
// exportUserData (callable)
// Returns all data we hold for the calling user: public profile, private
// profile data, listings, stay requests, full message content, friend edges,
// and submitted reports. Fulfills GDPR/CCPA right-to-access, and mirrors what
// onUserDeleted removes so the export is complete relative to what is stored.
// Call from the app: Functions.functions().httpsCallable("exportUserData")
// ---------------------------------------------------------------------------
export const exportUserData = functions.https.onCall(async (_data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in required.");

  const [
    profileSnap,
    privateSnap,
    listingsSnap,
    guestRequestsSnap,
    hostRequestsSnap,
    messagesSnap,
    friendEdgesASnap,
    friendEdgesBSnap,
    reportsSnap,
  ] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.doc(`users/${uid}/private/profile`).get(),
    db.collection("homes").where("hostUserID", "==", uid).get(),
    db.collection("stayRequests").where("guestUserID", "==", uid).get(),
    db.collection("stayRequests").where("hostUserID", "==", uid).get(),
    db.collection("messages").where("participants", "array-contains", uid).get(),
    db.collection("friendEdges").where("userA", "==", uid).get(),
    db.collection("friendEdges").where("userB", "==", uid).get(),
    db.collection("reports").where("reporterUserID", "==", uid).get(),
  ]);

  const withID = (d: FirebaseFirestore.QueryDocumentSnapshot) => ({ id: d.id, ...d.data() });

  return {
    profile: { ...(profileSnap.data() ?? {}), ...(privateSnap.data() ?? {}) },
    listings: listingsSnap.docs.map(withID),
    stayRequestsAsGuest: guestRequestsSnap.docs.map(withID),
    stayRequestsAsHost: hostRequestsSnap.docs.map(withID),
    messages: messagesSnap.docs.map(withID),
    friendEdges: [...friendEdgesASnap.docs, ...friendEdgesBSnap.docs].map(withID),
    reports: reportsSnap.docs.map(withID),
  };
});

// ---------------------------------------------------------------------------
// checkMessageRate (callable, internal helper)
// Rejects a message send if the user has exceeded 30 messages in 60 seconds.
// The iOS client calls this before writing to Firestore; it is not a hard
// enforcement layer — add Firestore rules or a write trigger for that.
// ---------------------------------------------------------------------------
const MESSAGE_RATE_LIMIT = 30;
const MESSAGE_RATE_WINDOW_MS = 60_000;

export const checkMessageRate = functions.https.onCall(async (_data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in required.");

  const since = admin.firestore.Timestamp.fromMillis(Date.now() - MESSAGE_RATE_WINDOW_MS);
  const snap = await db
    .collection("messages")
    .where("senderUserID", "==", uid)
    .where("timestamp", ">=", since)
    .get();

  if (snap.size >= MESSAGE_RATE_LIMIT) {
    throw new functions.https.HttpsError(
      "resource-exhausted",
      "Slow down — you're sending messages too quickly."
    );
  }
  return { allowed: true };
});

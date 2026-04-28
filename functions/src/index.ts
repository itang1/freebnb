import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

admin.initializeApp();

const db = admin.firestore();

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

    const [userDoc, senderDoc] = await Promise.all([
      db.collection("users").doc(recipientID).get(),
      db.collection("users").doc(msg.senderUserID).get(),
    ]);

    const fcmToken: string | undefined = userDoc.data()?.fcmToken;
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
  const batch = db.batch();
  const now = admin.firestore.FieldValue.serverTimestamp();

  const listingsSnap = await db
    .collection("homes")
    .where("hostUserID", "==", uid)
    .get();
  for (const doc of listingsSnap.docs) {
    batch.update(doc.ref, { deletedAt: now });
  }

  batch.delete(db.collection("users").doc(uid));
  await batch.commit();
});

// ---------------------------------------------------------------------------
// exportUserData (callable)
// Returns all data we hold for the calling user: profile, listings,
// stay requests, and message IDs. Fulfills GDPR/CCPA right-to-access.
// Call from the app: Functions.functions().httpsCallable("exportUserData")
// ---------------------------------------------------------------------------
export const exportUserData = functions.https.onCall(async (_data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in required.");

  const [profileSnap, listingsSnap, guestRequestsSnap, hostRequestsSnap, messagesSnap] =
    await Promise.all([
      db.collection("users").doc(uid).get(),
      db.collection("homes").where("hostUserID", "==", uid).get(),
      db.collection("stayRequests").where("guestUserID", "==", uid).get(),
      db.collection("stayRequests").where("hostUserID", "==", uid).get(),
      db.collection("messages").where("participants", "array-contains", uid).get(),
    ]);

  return {
    profile: profileSnap.data() ?? null,
    listings: listingsSnap.docs.map((d) => ({ id: d.id, ...d.data() })),
    stayRequestsAsGuest: guestRequestsSnap.docs.map((d) => ({ id: d.id, ...d.data() })),
    stayRequestsAsHost: hostRequestsSnap.docs.map((d) => ({ id: d.id, ...d.data() })),
    messageIDs: messagesSnap.docs.map((d) => d.id),
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

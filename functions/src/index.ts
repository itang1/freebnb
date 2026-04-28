import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

admin.initializeApp();

const db = admin.firestore();

// ---------------------------------------------------------------------------
// onMessageCreated
// Sends a push notification to the recipient of a new message.
// Fires on every new document in the `messages` collection.
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

    // Load the recipient's FCM token from their user profile.
    const userDoc = await db.collection("users").doc(recipientID).get();
    const fcmToken: string | undefined = userDoc.data()?.fcmToken;
    if (!fcmToken) return;

    // Load the sender's display name for the notification title.
    const senderDoc = await db.collection("users").doc(msg.senderUserID).get();
    const senderName: string = senderDoc.data()?.displayName ?? "FreeBNB";

    await admin.messaging().send({
      token: fcmToken,
      notification: {
        title: senderName,
        body: msg.text.length > 120 ? msg.text.slice(0, 120) + "…" : msg.text,
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
      data: {
        type: "message",
        senderUserID: msg.senderUserID,
      },
    });
  });

// ---------------------------------------------------------------------------
// onUserDeleted
// Cascade-deletes Firestore data when a Firebase Auth user is removed.
// This is a safety net; the iOS app also soft-deletes listings client-side
// before calling user.delete() so data disappears immediately in the UI.
// ---------------------------------------------------------------------------
export const onUserDeleted = functions.auth.user().onDelete(async (user) => {
  const uid = user.uid;
  const batch = db.batch();

  // Soft-delete all listings owned by this host.
  const listingsSnap = await db
    .collection("homes")
    .where("hostUserID", "==", uid)
    .get();
  const now = admin.firestore.FieldValue.serverTimestamp();
  for (const doc of listingsSnap.docs) {
    batch.update(doc.ref, { deletedAt: now });
  }

  // Delete the user profile document.
  batch.delete(db.collection("users").doc(uid));

  await batch.commit();
});

// Firebase web config for the moderation console.
//
// These values are not secrets — they identify the project, they don't authorise
// anything. Access is decided entirely by `firestore.rules`: the console can read
// or triage a report only when the signed-in account carries the `admin` custom
// claim, which `scripts/set_admin_claim.js` mints with Admin SDK credentials.
//
// Copy the values from the Firebase console:
//   Project settings → General → Your apps → Web app → SDK setup and configuration
//
// If no web app exists yet, add one there first (it costs nothing and needs no
// billing plan).
export const firebaseConfig = {
  apiKey: "REPLACE_ME",
  authDomain: "freebnb-6814a.firebaseapp.com",
  projectId: "freebnb-6814a",
  storageBucket: "freebnb-6814a.firebasestorage.app",
  messagingSenderId: "REPLACE_ME",
  appId: "REPLACE_ME",
};

// Point the console at the local emulators instead of production. Set to true
// when running `firebase emulators:start`.
export const useEmulators = false;

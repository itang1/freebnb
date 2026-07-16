// Firebase web config for the moderation console, exported for admin/app.js.
//
// These values are the public web-app config: safe to serve to anyone, because
// authorization lives in firestore.rules (the `admin` custom claim), not here.
// No imports and no initializeApp in this file; app.js owns initialization and
// only reads these two exports.
//
// Set useEmulators to true when running against the Local Emulator Suite.

export const firebaseConfig = {
  apiKey: "AIzaSyANXqRhcDCpbiM1K52SgayjYA8J1FAIyrs",
  authDomain: "freebnb-6814a.firebaseapp.com",
  projectId: "freebnb-6814a",
  storageBucket: "freebnb-6814a.firebasestorage.app",
  messagingSenderId: "886039659486",
  appId: "1:886039659486:web:58883564bb8b66d6d4534f",
  measurementId: "G-DHTL72X3PM",
};

export const useEmulators = false;

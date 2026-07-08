#!/usr/bin/env node
//
// Seeds the Firebase Auth + Firestore emulators with a handful of test users,
// listings, and stay requests so the app has data to click through without
// hand-creating accounts through the UI every time.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite only. It refuses to touch
// the real freebnb-6814a project unless you pass --prod AND set
// SEED_CONFIRM_PROD=1, because this writes fake accounts and listings that
// have no business existing in production.
//
// Usage:
//   1. firebase emulators:start --only auth,firestore
//   2. node scripts/seed_test_data.js
//
// Requires `npm install firebase-admin` once, run from the repo root (or from
// functions/, which already depends on it — this script also works if you
// point NODE_PATH at functions/node_modules).

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
if (useProd && process.env.SEED_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to seed the production project. Re-run with SEED_CONFIRM_PROD=1 " +
    "node scripts/seed_test_data.js --prod if you really mean it."
  );
  process.exit(1);
}

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
  process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "localhost:9099";
}

let admin;
try {
  admin = require("firebase-admin");
} catch {
  admin = require(path.join(__dirname, "..", "functions", "node_modules", "firebase-admin"));
}

admin.initializeApp({ projectId: "freebnb-6814a" });
const auth = admin.auth();
const db = admin.firestore();

const now = admin.firestore.FieldValue.serverTimestamp();

const users = [
  { uid: "seed-host-ada", email: "ada@seed.freebnb.test", password: "***REDACTED***", displayName: "Ada" },
  { uid: "seed-host-alan", email: "alan@seed.freebnb.test", password: "***REDACTED***", displayName: "Alan" },
  { uid: "seed-guest-grace", email: "grace@seed.freebnb.test", password: "***REDACTED***", displayName: "Grace" }
];

const amenities = {
  hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
  hasMicrowave: true, hasTV: false, hasWifi: true,
  hasPrivateGuestBathroom: true, hostHasPets: false, parkingDetails: "Street parking",
  hasInUnitLaundry: true, hasCoinLaundryNearby: false,
  providesPillows: true, providesBlankets: true, providesTowels: true,
  providesToiletries: false, foodProvision: "some"
};

const homes = [
  {
    id: "seed-home-ada-1",
    hostUserID: "seed-host-ada",
    hostName: "Ada",
    address: { street: "1 Innovation Way", city: "Cupertino", state: "CA", zip: "95014" },
    description: "Sunny guest room, five minutes from downtown.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
    visibility: "everyone"
  },
  {
    id: "seed-home-alan-1",
    hostUserID: "seed-host-alan",
    hostName: "Alan",
    address: { street: "42 Turing Rd", city: "Palo Alto", state: "CA", zip: "94301" },
    description: "Quiet couch in a converted attic studio.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { couch: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 3, kidsAllowed: false, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "moderate",
    visibility: "everyone"
  }
];

function daysFromNow(n) {
  return admin.firestore.Timestamp.fromDate(new Date(Date.now() + n * 86_400_000));
}

async function seedUsers() {
  for (const u of users) {
    await auth.createUser({ uid: u.uid, email: u.email, password: u.password, displayName: u.displayName })
      .catch((err) => {
        if (err.code !== "auth/uid-already-exists") throw err;
      });
    await db.collection("users").doc(u.uid).set({
      displayName: u.displayName,
      createdAt: now,
      updatedAt: now
    }, { merge: true });
    await db.collection("users").doc(u.uid).collection("private").doc("profile").set({
      email: u.email,
      savedListingIDs: [],
      blockedUserIDs: [],
      updatedAt: now
    }, { merge: true });
  }
  console.log(`Seeded ${users.length} users:`, users.map((u) => u.email).join(", "));
}

async function seedHomes() {
  for (const home of homes) {
    await db.collection("homes").doc(home.id).set(home, { merge: true });
  }
  console.log(`Seeded ${homes.length} listings.`);
}

async function seedStayRequests() {
  const requests = [
    {
      id: "seed-request-pending",
      listingID: homes[0].id,
      listingCity: homes[0].address.city,
      listingHostName: homes[0].hostName,
      hostUserID: homes[0].hostUserID,
      guestUserID: "seed-guest-grace",
      checkIn: daysFromNow(7),
      checkOut: daysFromNow(9),
      guestNote: "Excited to visit!",
      hostNote: null,
      status: "pending",
      createdAt: now,
      updatedAt: now
    },
    {
      id: "seed-request-accepted",
      listingID: homes[1].id,
      listingCity: homes[1].address.city,
      listingHostName: homes[1].hostName,
      hostUserID: homes[1].hostUserID,
      guestUserID: "seed-guest-grace",
      checkIn: daysFromNow(14),
      checkOut: daysFromNow(16),
      guestNote: null,
      hostNote: "Looking forward to hosting you.",
      status: "accepted",
      createdAt: now,
      updatedAt: now
    }
  ];
  for (const request of requests) {
    await db.collection("stayRequests").doc(request.id).set(request, { merge: true });
  }
  console.log(`Seeded ${requests.length} stay requests.`);
}

async function main() {
  console.log(`Seeding against ${useProd ? "PRODUCTION (freebnb-6814a)" : "the local emulator suite"}...`);
  await seedUsers();
  await seedHomes();
  await seedStayRequests();
  console.log("Done. Sign in with any seed-*@seed.freebnb.test / ***REDACTED*** account (or the dev@freebnb.test button in DEBUG builds) to explore.");
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

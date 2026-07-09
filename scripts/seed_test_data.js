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
// Pass --reset (alias --reset-homes) to wipe the demo-content collections before
// seeding: homes (with their private/location and accepted subcollections),
// stayRequests, friendEdges, conversations, and messages. This clears legacy data
// that predates the current schema so the demo starts clean. It deliberately does
// NOT delete `users` or Auth accounts. Against prod it still requires
// SEED_CONFIRM_PROD=1.
//
//   SEED_CONFIRM_PROD=1 node scripts/seed_test_data.js --prod --reset
//
// Requires `npm install firebase-admin` once, run from the repo root (or from
// functions/, which already depends on it — this script also works if you
// point NODE_PATH at functions/node_modules).

"use strict";

const path = require("path");

const useProd = process.argv.includes("--prod");
const resetFirst = process.argv.includes("--reset") || process.argv.includes("--reset-homes");
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

// `savedListingIDs` and `blockedUserIDs` are optional per-user overrides written
// into the private profile; omitted means an empty list. They let the seed mimic
// a lived-in account (bookmarks, a block) rather than a pristine one.
//
// The dev account matches the DEBUG "Sign in as dev@freebnb.test" button
// (ProfilePage). seedFriendEdges makes it an accepted friend of every other
// seed user (S1), so it can browse friends-only listings while testing; those
// listings also name it in allowedViewerIDs so the rules let it through.
const DEV_UID = "seed-dev-tester";
const users = [
  { uid: DEV_UID, email: "dev@freebnb.test", password: "***REDACTED***", displayName: "Dev Tester" },
  { uid: "seed-host-spongebob", email: "spongebob@seed.freebnb.test", password: "***REDACTED***", displayName: "SpongeBob SquarePants" },
  { uid: "seed-host-sandy", email: "sandy@seed.freebnb.test", password: "***REDACTED***", displayName: "Sandy Cheeks", savedListingIDs: ["seed-home-squidward-2"] },
  { uid: "seed-host-squidward", email: "squidward@seed.freebnb.test", password: "***REDACTED***", displayName: "Squidward Tentacles" },
  { uid: "seed-host-krabs", email: "krabs@seed.freebnb.test", password: "***REDACTED***", displayName: "Eugene Krabs" },
  { uid: "seed-host-pearl", email: "pearl@seed.freebnb.test", password: "***REDACTED***", displayName: "Pearl Krabs" },
  { uid: "seed-host-larry", email: "larry@seed.freebnb.test", password: "***REDACTED***", displayName: "Larry the Lobster" },
  { uid: "seed-host-puff", email: "puff@seed.freebnb.test", password: "***REDACTED***", displayName: "Mrs. Puff" },
  { uid: "seed-host-plankton", email: "plankton@seed.freebnb.test", password: "***REDACTED***", displayName: "Sheldon Plankton", blockedUserIDs: ["seed-host-krabs"] },
  { uid: "seed-host-karen", email: "karen@seed.freebnb.test", password: "***REDACTED***", displayName: "Karen Plankton" },
  { uid: "seed-host-neptune", email: "neptune@seed.freebnb.test", password: "***REDACTED***", displayName: "King Neptune" },
  { uid: "seed-host-mermaidman", email: "mermaidman@seed.freebnb.test", password: "***REDACTED***", displayName: "Mermaid Man" },
  { uid: "seed-guest-patrick", email: "patrick@seed.freebnb.test", password: "***REDACTED***", displayName: "Patrick Star", savedListingIDs: ["seed-home-spongebob-1", "seed-home-krabs-1"] },
  { uid: "seed-guest-gary", email: "gary@seed.freebnb.test", password: "***REDACTED***", displayName: "Gary the Snail", savedListingIDs: ["seed-home-krabs-1"] },
  { uid: "seed-guest-barnacleboy", email: "barnacleboy@seed.freebnb.test", password: "***REDACTED***", displayName: "Barnacle Boy" }
];

const amenities = {
  hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
  hasMicrowave: true, hasTV: false, hasWifi: true,
  hasPrivateGuestBathroom: true, hostHasPets: false, parkingDetails: "Street parking",
  hasInUnitLaundry: true, hasCoinLaundryNearby: false,
  providesPillows: true, providesBlankets: true, providesTowels: true,
  providesToiletries: false, foodProvision: "some"
};

// A cozier, fully-stocked variant: TV, all meals, toiletries, coin laundry nearby.
const cozyAmenities = {
  ...amenities, hasTV: true, hasInUnitLaundry: false, hasCoinLaundryNearby: true,
  providesToiletries: true, foodProvision: "all", parkingDetails: "Driveway parking"
};

// A bare-bones variant: no AC, shared bathroom, bring-your-own-everything.
const sparseAmenities = {
  ...amenities, hasAC: false, hasPrivateGuestBathroom: false, hasInUnitLaundry: false,
  hasCoinLaundryNearby: true, providesTowels: false, providesToiletries: false,
  foodProvision: "bareMinimum", parkingDetails: "No parking"
};

// `address` is the world-readable part only, and `allowedViewerIDs` is the read
// ACL the rules enforce friends-only visibility with. Each listing's street and
// exact coordinates are seeded separately into homes/{id}/private/location.
//
// The street + latitude/longitude below are REAL, geocoded addresses (mostly
// well-known public places), so the map pin and the "Open in Apple Maps" button
// land on an actual location. HomeDetailPage opens the stored coordinate, not the
// address string, so the two must stay consistent: if you change a street, re-
// geocode it and update the coordinate to match (don't hand-edit one without the
// other). The public homes/{id} doc gets the coordinate rounded by approximate().
const homes = [
  {
    id: "seed-home-spongebob-1",
    hostUserID: "seed-host-spongebob",
    hostName: "SpongeBob SquarePants",
    address: { city: "Honolulu", state: "HI", zip: "96815" },
    location: { street: "2259 Kalakaua Avenue", latitude: 21.2773331, longitude: -157.8289679 },
    description: "Bright yellow beach bungalow two blocks from the water, squarish and cheerful just like its owner. Great for anyone who loves the smell of fry cooking and doesn't mind an early jellyfishing session.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-spongebob"]
  },
  {
    id: "seed-home-sandy-1",
    hostUserID: "seed-host-sandy",
    hostName: "Sandy Cheeks",
    address: { city: "Houston", state: "TX", zip: "77058" },
    location: { street: "1601 East NASA Parkway", latitude: 29.5488211, longitude: -95.0980120 },
    description: "Quiet guest room near the space center, decked out with rock-climbing gear and a homemade oxygen-tank display. Karate mat included. Not much room to swing a lasso, but it's snug.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { couch: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 3, kidsAllowed: false, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "moderate",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-sandy"]
  },
  {
    id: "seed-home-squidward-1",
    hostUserID: "seed-host-squidward",
    hostName: "Squidward Tentacles",
    address: { city: "New Orleans", state: "LA", zip: "70116" },
    location: { street: "1132 Royal Street", latitude: 29.9614606, longitude: -90.0615030 },
    description: "A tasteful French Quarter apartment for the discerning guest. Clarinet practice happens nightly, whether you like it or not. Please admire the self-portraits and keep the noise to a civilized minimum.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 4, kidsAllowed: false, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "strict",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-squidward"]
  },
  {
    id: "seed-home-krabs-1",
    hostUserID: "seed-host-krabs",
    hostName: "Eugene Krabs",
    address: { city: "Bar Harbor", state: "ME", zip: "04609" },
    location: { street: "7 Newport Drive", latitude: 44.3905728, longitude: -68.2018487 },
    description: "Waterfront anchor-up room above the family restaurant. Wake to the smell of the sea and the sound of a cash register. First guest gets the good mattress, everyone else negotiates. No refunds, money is money.",
    contactPreference: "contactInfo",
    hostContactInfo: "Call the Krusty Krab and ask for Mr. Krabs",
    hostMotivation: "open",
    sleeping: { numGuestRooms: 2, arrangements: { bed: 1, futon: 1 } },
    guestPolicy: { maxGuests: 3, maxStayDays: 5, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "strict",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-krabs"]
  },
  {
    id: "seed-home-pearl-1",
    hostUserID: "seed-host-pearl",
    hostName: "Pearl Krabs",
    address: { city: "Los Angeles", state: "CA", zip: "90028" },
    location: { street: "6801 Hollywood Boulevard", latitude: 34.1026902, longitude: -118.3404676 },
    description: "Bright loft steps from the mall, perfect for a shopping weekend. Comes with unlimited playlists and a walk-in closet you are welcome to be jealous of. Squad sleepovers encouraged.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1, airMattress: 2 } },
    guestPolicy: { maxGuests: 4, maxStayDays: 3, kidsAllowed: true, guestPetsAllowed: true },
    amenities: cozyAmenities,
    cancellationPolicy: "flexible",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-pearl"]
  },
  {
    id: "seed-home-larry-1",
    hostUserID: "seed-host-larry",
    hostName: "Larry the Lobster",
    address: { city: "San Diego", state: "CA", zip: "92109" },
    location: { street: "3146 Mission Boulevard", latitude: 32.7708880, longitude: -117.2520465 },
    description: "Beachfront crash pad for active guests. Home gym, protein bar, and a paddleboard rack by the door. We lift at sunrise, no excuses. Towels provided, gains not guaranteed.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { couch: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 6, kidsAllowed: false, guestPetsAllowed: true },
    amenities,
    cancellationPolicy: "moderate",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-larry"]
  },
  {
    id: "seed-home-puff-1",
    hostUserID: "seed-host-puff",
    hostName: "Mrs. Puff",
    address: { city: "Annapolis", state: "MD", zip: "21401" },
    location: { street: "80 Compromise Street", latitude: 38.9757572, longitude: -76.4855636 },
    description: "Calm harborside room near the boating school. Quiet, tidy, and absolutely no driving lessons on the premises, thank you. A cup of tea and an early bedtime await.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 10, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-puff"]
  },
  {
    id: "seed-home-plankton-1",
    hostUserID: "seed-host-plankton",
    hostName: "Sheldon Plankton",
    address: { city: "Menlo Park", state: "CA", zip: "94025" },
    location: { street: "1 Hacker Way", latitude: 37.4846680, longitude: -122.1483655 },
    description: "A very small but very smart studio in the heart of the peninsula. Wired for a home lab and late-night scheming. Friends only, because I do not trust the general public with the secret formula.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 1, arrangements: { floorMat: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 2, kidsAllowed: false, guestPetsAllowed: false },
    amenities: sparseAmenities,
    cancellationPolicy: "strict",
    visibility: "friendsOnly",
    allowedViewerIDs: ["seed-host-plankton", "seed-guest-patrick", DEV_UID]
  },
  {
    id: "seed-home-spongebob-2",
    hostUserID: "seed-host-spongebob",
    hostName: "SpongeBob SquarePants",
    address: { city: "Key West", state: "FL", zip: "33040" },
    location: { street: "500 Duval Street", latitude: 24.5556012, longitude: -81.8027503 },
    description: "A second pineapple, this one down in the Keys! Snorkel gear by the door, ukulele on the wall, and Gary visits on weekends. Sunsets included at no extra charge.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1, couch: 1 } },
    guestPolicy: { maxGuests: 3, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: true },
    amenities: cozyAmenities,
    cancellationPolicy: "flexible",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-spongebob"]
  },
  {
    id: "seed-home-sandy-2",
    hostUserID: "seed-host-sandy",
    hostName: "Sandy Cheeks",
    address: { city: "Austin", state: "TX", zip: "78701" },
    location: { street: "600 Congress Avenue", latitude: 30.2684980, longitude: -97.7431110 },
    description: "Downtown Texas hideout for close friends passing through. Backyard oak tree with a rope swing, a workshop full of half-built inventions, and the best barbecue recommendations in town.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 5, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "moderate",
    visibility: "friendsOnly",
    allowedViewerIDs: ["seed-host-sandy", "seed-guest-patrick", DEV_UID]
  },
  {
    id: "seed-home-squidward-2",
    hostUserID: "seed-host-squidward",
    hostName: "Squidward Tentacles",
    address: { city: "Portland", state: "OR", zip: "97205" },
    location: { street: "1219 Southwest Park Avenue", latitude: 45.5165483, longitude: -122.6834106 },
    description: "An artist's retreat beside the museum, for guests who appreciate the finer things. Easels provided. Interpretive dance in common areas is, regrettably, permitted but not encouraged.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 4, kidsAllowed: false, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "strict",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-squidward"]
  },
  {
    id: "seed-home-krabs-2",
    hostUserID: "seed-host-krabs",
    hostName: "Eugene Krabs",
    address: { city: "Miami Beach", state: "FL", zip: "33139" },
    location: { street: "1300 Ocean Drive", latitude: 25.7841289, longitude: -80.1301201 },
    description: "South Beach condo with an ocean view worth every penny, and I do mean every penny. Rooftop deck, valet, and a safe I check twice nightly. Treat it well and we will get along famously.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 2, arrangements: { bed: 2 } },
    guestPolicy: { maxGuests: 4, maxStayDays: 6, kidsAllowed: true, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "moderate",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-krabs"]
  },
  {
    id: "seed-home-karen-1",
    hostUserID: "seed-host-karen",
    hostName: "Karen Plankton",
    address: { city: "San Jose", state: "CA", zip: "95113" },
    location: { street: "201 South Market Street", latitude: 37.3314040, longitude: -121.8901566 },
    description: "A sleek, fully-automated smart loft downtown. Lights, blinds, and coffee all voice-controlled by yours truly. I will remind you of checkout precisely on time. Sarcasm included at no extra charge.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 5, kidsAllowed: false, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "moderate",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-karen"]
  },
  {
    id: "seed-home-neptune-1",
    hostUserID: "seed-host-neptune",
    hostName: "King Neptune",
    address: { city: "Newport", state: "RI", zip: "02840" },
    location: { street: "367 Bellevue Avenue", latitude: 41.4777971, longitude: -71.3088718 },
    description: "A gilded seaside mansion for guests of impeccable taste. Ballroom, private beach, and a trident collection you may look at but not touch. I am a king, so do mind your manners.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 3, arrangements: { bed: 3 } },
    guestPolicy: { maxGuests: 6, maxStayDays: 4, kidsAllowed: true, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "strict",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-neptune"]
  },
  {
    id: "seed-home-mermaidman-1",
    hostUserID: "seed-host-mermaidman",
    hostName: "Mermaid Man",
    address: { city: "Sarasota", state: "FL", zip: "34236" },
    location: { street: "1565 1st Street", latitude: 27.3373443, longitude: -82.5393616 },
    description: "A cozy room at the Shady Shoals rest home for retired heroes. Early dinners, afternoon naps, and the occasional crime-fighting drill. EVIL is not permitted on the premises. Barnacle Boy may or may not be around.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 14, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
    visibility: "everyone",
    allowedViewerIDs: ["seed-host-mermaidman"]
  }
];

// Fast lookup so stay requests can pull denormalized listing fields by id.
const homesByID = Object.fromEntries(homes.map((h) => [h.id, h]));

// Must match Home.approximate(_:) in Swift: the public coordinate is blurred.
function approximate(value) {
  return Math.round(value * 100) / 100;
}

// Mirror of Geohash.encode(...) in Swift: the base-32 geohash of the blurred
// public coordinate, used as the proximity index key (feature 11). Keep the
// alphabet and precision in sync with the Swift implementation.
const GEOHASH_BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";
function geohashEncode(latitude, longitude, precision = 6) {
  let latRange = [-90, 90];
  let lonRange = [-180, 180];
  let hash = "";
  let bit = 0;
  let ch = 0;
  let evenBit = true;
  while (hash.length < precision) {
    if (evenBit) {
      const mid = (lonRange[0] + lonRange[1]) / 2;
      if (longitude >= mid) { ch |= 1 << (4 - bit); lonRange[0] = mid; }
      else { lonRange[1] = mid; }
    } else {
      const mid = (latRange[0] + latRange[1]) / 2;
      if (latitude >= mid) { ch |= 1 << (4 - bit); latRange[0] = mid; }
      else { latRange[1] = mid; }
    }
    evenBit = !evenBit;
    if (bit < 4) {
      bit += 1;
    } else {
      hash += GEOHASH_BASE32[ch];
      bit = 0;
      ch = 0;
    }
  }
  return hash;
}

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
      savedListingIDs: u.savedListingIDs ?? [],
      blockedUserIDs: u.blockedUserIDs ?? [],
      updatedAt: now
    }, { merge: true });
  }
  console.log(`Seeded ${users.length} users:`, users.map((u) => u.email).join(", "));
}

// Recursively deletes a whole collection (documents plus any subcollections).
// Uses recursiveDelete where available (admin SDK 10+); otherwise sweeps the
// subcollections manually. Returns the number of top-level docs removed.
async function deleteCollection(name) {
  const ref = db.collection(name);
  const snapshot = await ref.get();
  if (snapshot.empty) return 0;
  if (typeof db.recursiveDelete === "function") {
    await db.recursiveDelete(ref);
  } else {
    for (const doc of snapshot.docs) {
      for (const sub of await doc.ref.listCollections()) {
        const subDocs = await sub.get();
        for (const s of subDocs.docs) await s.ref.delete();
      }
      await doc.ref.delete();
    }
  }
  return snapshot.size;
}

// Clears the demo-content collections before re-seeding: listings (and their
// private/location + accepted subcollections), plus the stay requests, friend
// edges, conversations, and messages that reference them. Deliberately does NOT
// touch `users` or Auth accounts — those can include real sign-ins, and orphaned
// profiles are harmless. This is what wipes the pre-migration legacy data so the
// demo starts from a clean, consistent state.
async function resetDemoData() {
  const collections = ["homes", "stayRequests", "friendEdges", "conversations", "messages"];
  for (const name of collections) {
    const count = await deleteCollection(name);
    console.log(`Reset: deleted ${count} doc(s) from ${name}.`);
  }
}

async function seedHomes() {
  for (const home of homes) {
    const { location, ...publicListing } = home;
    publicListing.latitude = approximate(location.latitude);
    publicListing.longitude = approximate(location.longitude);
    publicListing.geohash = geohashEncode(publicListing.latitude, publicListing.longitude);
    // The feed orders by createdAt, and an order-by excludes docs missing the
    // field, so a seeded listing without one never shows. Stamp it (L3).
    publicListing.createdAt = now;
    await db.collection("homes").doc(home.id).set(publicListing, { merge: true });
    await db.collection("homes").doc(home.id)
      .collection("private").doc("location").set(location, { merge: true });
  }
  console.log(`Seeded ${homes.length} listings.`);
}

// Builds a stay-request document, pulling the denormalized listing city and host
// name straight off the listing so they never drift from the home they point at.
function stayRequest({ id, listingID, guestUserID, checkInDays, checkOutDays, status, guestNote = null, hostNote = null }) {
  const home = homesByID[listingID];
  if (!home) throw new Error(`stayRequest references unknown listing ${listingID}`);
  return {
    id,
    listingID,
    listingCity: home.address.city,
    listingHostName: home.hostName,
    hostUserID: home.hostUserID,
    guestUserID,
    checkIn: daysFromNow(checkInDays),
    checkOut: daysFromNow(checkOutDays),
    guestNote,
    hostNote,
    status,
    createdAt: now,
    updatedAt: now
  };
}

// A spread of guests, hosts, and statuses so the Stays tab shows every state:
// pending (awaiting host), accepted (confirmed), declined, and cancelled.
const stayRequests = [
    stayRequest({ id: "seed-request-pending", listingID: "seed-home-spongebob-1", guestUserID: "seed-guest-patrick",
      checkInDays: 7, checkOutDays: 9, status: "pending", guestNote: "Excited to visit, buddy!" }),
    stayRequest({ id: "seed-request-accepted", listingID: "seed-home-sandy-1", guestUserID: "seed-guest-patrick",
      checkInDays: 14, checkOutDays: 16, status: "accepted", hostNote: "Looking forward to hosting you. Bring your karate gi." }),
    stayRequest({ id: "seed-request-gary-krabs", listingID: "seed-home-krabs-1", guestUserID: "seed-guest-gary",
      checkInDays: 3, checkOutDays: 6, status: "accepted", guestNote: "Meow.", hostNote: "Cash only. Room's yours, snail." }),
    stayRequest({ id: "seed-request-patrick-squidward", listingID: "seed-home-squidward-1", guestUserID: "seed-guest-patrick",
      checkInDays: 10, checkOutDays: 12, status: "declined", guestNote: "can i stay at your place", hostNote: "No." }),
    stayRequest({ id: "seed-request-mermaidman-larry", listingID: "seed-home-larry-1", guestUserID: "seed-host-mermaidman",
      checkInDays: 20, checkOutDays: 23, status: "pending", guestNote: "Need a training base near the beach. EVIL never rests." }),
    stayRequest({ id: "seed-request-barnacleboy-pearl", listingID: "seed-home-pearl-1", guestUserID: "seed-guest-barnacleboy",
      checkInDays: 5, checkOutDays: 8, status: "accepted", guestNote: "Do you get the shopping channel?", hostNote: "OMG yes, welcome!" }),
    stayRequest({ id: "seed-request-patrick-plankton", listingID: "seed-home-plankton-1", guestUserID: "seed-guest-patrick",
      checkInDays: 2, checkOutDays: 4, status: "cancelled", guestNote: "wait is this the chum place", hostNote: null }),
    stayRequest({ id: "seed-request-gary-spongebob2", listingID: "seed-home-spongebob-2", guestUserID: "seed-guest-gary",
      checkInDays: 30, checkOutDays: 35, status: "pending", guestNote: "Meow meow." }),
    stayRequest({ id: "seed-request-sandy-krabs2", listingID: "seed-home-krabs-2", guestUserID: "seed-host-sandy",
      checkInDays: 12, checkOutDays: 15, status: "accepted", guestNote: "A little vacation from Texas heat.", hostNote: "Money's money. See you in Miami." }),
    stayRequest({ id: "seed-request-neptune-squidward2", listingID: "seed-home-squidward-2", guestUserID: "seed-host-neptune",
      checkInDays: 40, checkOutDays: 42, status: "pending", guestNote: "A king requires the finest suite." })
];

async function seedStayRequests() {
  for (const request of stayRequests) {
    await db.collection("stayRequests").doc(request.id).set(request, { merge: true });
    // An accepted stay is what discloses the host's street address; the app
    // writes this marker on accept, so the seed has to as well.
    if (request.status === "accepted") {
      await db.collection("homes").doc(request.listingID)
        .collection("accepted").doc(request.guestUserID)
        .set({ requestID: request.id, guestUserID: request.guestUserID, createdAt: now }, { merge: true });
    }
  }
  console.log(`Seeded ${stayRequests.length} stay requests.`);
}

// Builds a friend-edge document. The doc id and userA/userB ordering mirror
// FriendEdge.edgeID in Swift: the two UIDs sorted and joined by "_", with userA
// the alphabetically smaller. `initiator` is whoever sent the request.
function friendEdge(a, b, status, initiator) {
  const [userA, userB] = [a, b].sort();
  return { id: `${userA}_${userB}`, userA, userB, status, initiator };
}

// A friend graph: mostly accepted, plus a couple of pending requests so the
// Friends tab shows incoming/outgoing states. Two invariants hold here:
//   1. Every stay request below is between two accepted friends — you connect
//      before you ask to stay — so each guest/host pair has an accepted edge.
//   2. friendsOnly listings (Plankton, Sandy's Austin place) name their viewers
//      in allowedViewerIDs, and those viewers are accepted friends of the host.
// The dev account is wired to be friends with everyone at the end (S1).
const explicitFriendEdges = [
    friendEdge("seed-guest-patrick", "seed-host-spongebob", "accepted", "seed-guest-patrick"),
    friendEdge("seed-guest-patrick", "seed-host-sandy", "accepted", "seed-host-sandy"),
    friendEdge("seed-guest-patrick", "seed-host-plankton", "accepted", "seed-guest-patrick"),
    friendEdge("seed-host-spongebob", "seed-host-sandy", "accepted", "seed-host-spongebob"),
    friendEdge("seed-host-spongebob", "seed-host-squidward", "accepted", "seed-host-squidward"),
    friendEdge("seed-host-spongebob", "seed-guest-gary", "accepted", "seed-host-spongebob"),
    friendEdge("seed-host-squidward", "seed-host-krabs", "accepted", "seed-host-krabs"),
    friendEdge("seed-host-krabs", "seed-host-pearl", "accepted", "seed-host-krabs"),
    friendEdge("seed-host-larry", "seed-host-sandy", "accepted", "seed-host-larry"),
    friendEdge("seed-host-plankton", "seed-host-karen", "accepted", "seed-host-plankton"),
    friendEdge("seed-host-mermaidman", "seed-guest-barnacleboy", "accepted", "seed-host-mermaidman"),
    // Accepted edges that back the stay requests below (guest befriended host first).
    friendEdge("seed-guest-gary", "seed-host-krabs", "accepted", "seed-guest-gary"),
    friendEdge("seed-guest-patrick", "seed-host-squidward", "accepted", "seed-guest-patrick"),
    friendEdge("seed-host-mermaidman", "seed-host-larry", "accepted", "seed-host-mermaidman"),
    friendEdge("seed-guest-barnacleboy", "seed-host-pearl", "accepted", "seed-guest-barnacleboy"),
    friendEdge("seed-host-sandy", "seed-host-krabs", "accepted", "seed-host-sandy"),
    friendEdge("seed-host-neptune", "seed-host-squidward", "accepted", "seed-host-neptune"),
    // Pending: Patrick asked Gary (outgoing for Patrick), Neptune asked Krabs,
    // Pearl asked Patrick (incoming for Patrick).
    friendEdge("seed-guest-patrick", "seed-guest-gary", "pending", "seed-guest-patrick"),
    friendEdge("seed-host-neptune", "seed-host-krabs", "pending", "seed-host-neptune"),
    friendEdge("seed-host-pearl", "seed-guest-patrick", "pending", "seed-host-pearl")
];

// S1: the dev account is an accepted friend of every other seed user, so it can
// see every friends-only listing while testing.
const devFriendEdges = users
  .filter((u) => u.uid !== DEV_UID)
  .map((u) => friendEdge(DEV_UID, u.uid, "accepted", DEV_UID));

const friendEdges = [...explicitFriendEdges, ...devFriendEdges];

async function seedFriendEdges() {
  for (const edge of friendEdges) {
    const { id, ...data } = edge;
    await db.collection("friendEdges").doc(id).set({ ...data, createdAt: now, updatedAt: now }, { merge: true });
  }
  console.log(`Seeded ${friendEdges.length} friend edges.`);
}

// Writes a message thread between two users: the individual `messages` documents
// plus the denormalized `conversations/{id}` summary the app reads for the list.
// `msgs` is oldest-to-newest as authored; each carries `from` and `minsAgo`.
// unreadCounts advances the recipient on each message and zeroes the sender,
// exactly as functions/src/index.ts maintains it on a real send.
async function seedThread(a, b, msgs, mutedBy = []) {
  const participants = [a, b].sort();
  const conversationID = participants.join("_");
  const unread = { [a]: 0, [b]: 0 };
  let lastMessage = null;
  let lastTimestamp = null;
  msgs.forEach((m, index) => {
    const ts = admin.firestore.Timestamp.fromDate(new Date(Date.now() - m.minsAgo * 60_000));
    m._ts = ts;
    m._id = `seed-msg-${conversationID}-${index}`;
    const recipient = m.from === a ? b : a;
    unread[recipient] += 1;
    unread[m.from] = 0;
    lastMessage = { text: m.text, senderUserID: m.from, timestamp: ts };
    lastTimestamp = ts;
  });
  for (const m of msgs) {
    await db.collection("messages").doc(m._id).set({
      id: m._id, senderUserID: m.from, text: m.text, timestamp: m._ts, participants
    }, { merge: true });
  }
  await db.collection("conversations").doc(conversationID).set({
    participants, lastMessage, updatedAt: lastTimestamp, unreadCounts: unread, mutedBy
  }, { merge: true });
}

// Each thread: the two participants, the messages oldest-to-newest, and an
// optional mutedBy list. Kept as data so it can be validated without Firestore.
const conversationThreads = [
  {
    a: "seed-guest-patrick", b: "seed-host-spongebob", msgs: [
      { from: "seed-host-spongebob", text: "Hey buddy! Come stay at the pineapple next week?", minsAgo: 220 },
      { from: "seed-guest-patrick", text: "Is mayonnaise a reservation?", minsAgo: 210 },
      { from: "seed-host-spongebob", text: "No, Patrick. I sent you a stay request. Just tap accept!", minsAgo: 205 },
      { from: "seed-guest-patrick", text: "OH. Okay accepting it now!!", minsAgo: 200 }
    ]
  },
  {
    a: "seed-guest-patrick", b: "seed-host-sandy", msgs: [
      { from: "seed-host-sandy", text: "Your stay in Houston is confirmed, y'all. Bring a jacket for the dome.", minsAgo: 330 },
      { from: "seed-guest-patrick", text: "do you have snacks", minsAgo: 320 },
      { from: "seed-host-sandy", text: "...yes, Patrick. I have snacks.", minsAgo: 315 }
    ]
  },
  {
    a: "seed-guest-gary", b: "seed-host-krabs", msgs: [
      { from: "seed-guest-gary", text: "Meow.", minsAgo: 500 },
      { from: "seed-host-krabs", text: "A fine, quiet guest. Room's yours, snail. Cash only, arr.", minsAgo: 495 }
    ]
  },
  {
    a: "seed-guest-patrick", b: "seed-host-squidward", msgs: [
      { from: "seed-guest-patrick", text: "can i stay at your place in new orleans", minsAgo: 1000 },
      { from: "seed-host-squidward", text: "No.", minsAgo: 995 }
    ]
  },
  {
    // Barnacle Boy has muted Mermaid Man, so these arrive without a push.
    a: "seed-host-mermaidman", b: "seed-guest-barnacleboy", mutedBy: ["seed-guest-barnacleboy"], msgs: [
      { from: "seed-host-mermaidman", text: "EVIL is afoot! We must patrol Sarasota at dawn!", minsAgo: 90 },
      { from: "seed-host-mermaidman", text: "Barnacle Boy? Are you napping again?", minsAgo: 30 }
    ]
  }
];

async function seedConversations() {
  for (const t of conversationThreads) {
    await seedThread(t.a, t.b, t.msgs, t.mutedBy ?? []);
  }
  console.log(`Seeded ${conversationThreads.length} conversation threads.`);
}

async function main() {
  console.log(`Seeding against ${useProd ? "PRODUCTION (freebnb-6814a)" : "the local emulator suite"}...`);
  if (resetFirst) {
    await resetDemoData();
  }
  await seedUsers();
  await seedHomes();
  await seedStayRequests();
  await seedFriendEdges();
  await seedConversations();
  console.log("Done. Sign in with any seed-*@seed.freebnb.test / ***REDACTED*** account (or the dev@freebnb.test button in DEBUG builds) to explore.");
  process.exit(0);
}

// Only seed when run directly. Requiring the module (e.g. from a validator)
// exposes the datasets below without connecting to Firestore.
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { users, homes, homesByID, stayRequests, friendEdges, conversationThreads };

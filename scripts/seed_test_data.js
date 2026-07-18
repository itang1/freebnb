#!/usr/bin/env node
//
// Seeds the Firebase Auth + Firestore emulators with a handful of test users,
// listings, and stay requests so the app has data to click through without
// hand-creating accounts through the UI every time.
//
// SAFE BY DEFAULT: targets the Local Emulator Suite only. It refuses to touch
// the real freebnb-6814a project unless you pass --prod AND set
// SEED_CONFIRM_PROD=1.
//
// Prod additionally requires SEED_PROD_PASSWORD (see EMULATOR_PASSWORD below):
// the cast is real in prod, this file is public, and a password committed here
// would be an open door to every listing the cast can see. Re-running --prod
// with a new SEED_PROD_PASSWORD rotates the whole cast.
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
const { createRequire } = require("module");
const { searchTerms } = require("./search_terms");

const useProd = process.argv.includes("--prod");
const resetFirst = process.argv.includes("--reset") || process.argv.includes("--reset-homes");
if (useProd && process.env.SEED_CONFIRM_PROD !== "1") {
  console.error(
    "Refusing to seed the production project. Re-run with SEED_CONFIRM_PROD=1 " +
    "node scripts/seed_test_data.js --prod if you really mean it."
  );
  process.exit(1);
}

// The cast's sign-in password.
//
// An emulator account is a throwaway on a local port, so its password protects
// nothing and lives here in the open — TestProfiles.swift hardcodes the same
// value for the DEBUG sign-in buttons, and the two have to agree.
//
// Production is the opposite: those accounts are real, hold real friend edges,
// and see real friends-only listings — and this file is public. A committed
// password would be an open front door, which is exactly what it was until
// 2026-07-16. So --prod refuses to run without SEED_PROD_PASSWORD and never
// falls back to the value below. Keep that secret out of the repo (a password
// manager, or `read -s`), and note that anyone who learns it gets whatever the
// cast can see.
const EMULATOR_PASSWORD = "emulator-only";
const prodPassword = process.env.SEED_PROD_PASSWORD;
if (useProd && !prodPassword) {
  console.error(
    "Refusing to seed production without SEED_PROD_PASSWORD. The cast's prod\n" +
    "password must not live in this repo — the repo is public. Set it to\n" +
    "something only you know:\n" +
    "  SEED_PROD_PASSWORD='...' SEED_CONFIRM_PROD=1 node scripts/seed_test_data.js --prod\n" +
    "Re-running with a new value rotates every cast account's password."
  );
  process.exit(1);
}
if (useProd && prodPassword.length < 6) {
  // Firebase's own floor; failing here beats failing halfway through the cast.
  console.error("SEED_PROD_PASSWORD must be at least 6 characters.");
  process.exit(1);
}
const castPassword = useProd ? prodPassword : EMULATOR_PASSWORD;

if (!useProd) {
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "localhost:8080";
  process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "localhost:9099";
}

// Use the modular firebase-admin API (getAuth/getFirestore, v10+). The legacy
// namespaced accessors (admin.auth(), admin.firestore.FieldValue) were removed
// in firebase-admin v13, so a repo-root `npm install firebase-admin` (which now
// pulls v14) made this script crash on load and seed nothing. Prefer a
// firebase-admin at the repo root; fall back to the copy in functions/, which
// always depends on it. createRequire from functions/package.json resolves the
// `firebase-admin/*` subpaths through that package's exports map.
let adminRequire = require;
try {
  require.resolve("firebase-admin/app");
} catch {
  adminRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));
}
const { initializeApp } = adminRequire("firebase-admin/app");
const { getAuth } = adminRequire("firebase-admin/auth");
const { getFirestore, FieldValue, Timestamp } = adminRequire("firebase-admin/firestore");

initializeApp({ projectId: "freebnb-6814a" });
const auth = getAuth();
const db = getFirestore();

const now = FieldValue.serverTimestamp();

// `savedListingIDs` and `blockedUserIDs` are optional per-user overrides written
// into the private profile; omitted means an empty list. They let the seed mimic
// a lived-in account (bookmarks, a block) rather than a pristine one.
//
// The dev and guest-tester accounts match the DEBUG-only "Sign in as devna" /
// "Sign in as guest" buttons (WelcomePage, ProfilePage). Both are real,
// persistent seed users rather than throwaway anonymous Auth accounts, so
// "browsing without an account" never creates a real account connected to
// nobody — it signs into a fixed account connected only to the SpongeBob
// cast. seedFriendEdges makes each an accepted friend of every other seed
// user (S1), so both can browse friends-only listings while testing; those
// listings also name them in allowedViewerIDs so the rules let them through.
const DEV_UID = "seed-dev-tester";
const GUEST_UID = "seed-guest-tester";
const TEST_ACCOUNT_UIDS = [DEV_UID, GUEST_UID];
const users = [
  { uid: DEV_UID, email: "dev@freebnb.test", displayName: "Devna" },
  { uid: GUEST_UID, email: "guest@freebnb.test", displayName: "Guesta" },
  { uid: "seed-host-spongebob", email: "spongebob@seed.freebnb.test", displayName: "SpongeBob SquarePants" },
  { uid: "seed-host-sandy", email: "sandy@seed.freebnb.test", displayName: "Sandy Cheeks", savedListingIDs: ["seed-home-squidward-2"] },
  { uid: "seed-host-squidward", email: "squidward@seed.freebnb.test", displayName: "Squidward Tentacles" },
  { uid: "seed-host-krabs", email: "krabs@seed.freebnb.test", displayName: "Eugene Krabs" },
  { uid: "seed-host-pearl", email: "pearl@seed.freebnb.test", displayName: "Pearl Krabs" },
  { uid: "seed-host-larry", email: "larry@seed.freebnb.test", displayName: "Larry the Lobster" },
  { uid: "seed-host-puff", email: "puff@seed.freebnb.test", displayName: "Mrs. Puff" },
  { uid: "seed-host-plankton", email: "plankton@seed.freebnb.test", displayName: "Sheldon Plankton", blockedUserIDs: ["seed-host-krabs"] },
  { uid: "seed-host-karen", email: "karen@seed.freebnb.test", displayName: "Karen Plankton" },
  { uid: "seed-host-neptune", email: "neptune@seed.freebnb.test", displayName: "King Neptune" },
  { uid: "seed-host-mermaidman", email: "mermaidman@seed.freebnb.test", displayName: "Mermaid Man" },
  { uid: "seed-guest-patrick", email: "patrick@seed.freebnb.test", displayName: "Patrick Star", savedListingIDs: ["seed-home-spongebob-1", "seed-home-krabs-1"] },
  { uid: "seed-guest-gary", email: "gary@seed.freebnb.test", displayName: "Gary the Snail", savedListingIDs: ["seed-home-krabs-1"] },
  { uid: "seed-guest-barnacleboy", email: "barnacleboy@seed.freebnb.test", displayName: "Barnacle Boy" }
];

// The accessibility trio (feature 17) is false here on purpose: most hosts have
// not answered, and `false` means "did not say", never "said no". Seeding it true
// everywhere would make the accessibility filters look like they match anything.
const amenities = {
  hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
  hasMicrowave: true, hasTV: false, hasWifi: true,
  hasPrivateGuestBathroom: true, hostHasPets: false, parkingDetails: "Street parking",
  hasInUnitLaundry: true, hasCoinLaundryNearby: false,
  providesPillows: true, providesBlankets: true, providesTowels: true,
  providesToiletries: false, foodProvision: "some",
  hasStepFreeEntry: false, hasElevator: false, hasAccessibleBathroom: false
};

// A cozier, fully-stocked variant: TV, all meals, toiletries, coin laundry nearby.
// Also the ground-floor, step-free listing, so the accessibility filters have
// something to return in the demo.
const cozyAmenities = {
  ...amenities, hasTV: true, hasInUnitLaundry: false, hasCoinLaundryNearby: true,
  providesToiletries: true, foodProvision: "all", parkingDetails: "Driveway parking",
  hasStepFreeEntry: true, hasAccessibleBathroom: true
};

// A bare-bones variant: no AC, shared bathroom, bring-your-own-everything.
// An upper-floor apartment: there is an elevator, and nothing else is claimed.
const sparseAmenities = {
  ...amenities, hasAC: false, hasPrivateGuestBathroom: false, hasInUnitLaundry: false,
  hasCoinLaundryNearby: true, providesTowels: false, providesToiletries: false,
  foodProvision: "bareMinimum", parkingDetails: "No parking",
  hasElevator: true
};

// `address` is the city-level part only. The read ACL (`allowedViewerIDs`) is
// not written here: seedHomes() computes it from the seeded friend graph (host
// + accepted friends), exactly as rebuildListingACLs does in production. Each
// listing's street and exact coordinates are seeded separately into
// homes/{id}/private/location.
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
    title: "The Waikiki Pineapple",
    address: { city: "Honolulu", state: "HI", zip: "96815" },
    location: { street: "2259 Kalakaua Avenue", latitude: 21.2773331, longitude: -157.8289679 },
    description: "Bright yellow beach bungalow two blocks from the water, squarish and cheerful just like its owner. Great for anyone who loves the smell of fry cooking and doesn't mind an early jellyfishing session.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 1, bedSizes: { queen: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
  },
  {
    id: "seed-home-sandy-1",
    hostUserID: "seed-host-sandy",
    hostName: "Sandy Cheeks",
    title: "The Space Center Room",
    address: { city: "Houston", state: "TX", zip: "77058" },
    location: { street: "1601 East NASA Parkway", latitude: 29.5488211, longitude: -95.0980120 },
    description: "Quiet guest room near the space center, decked out with rock-climbing gear and a homemade oxygen-tank display. Karate mat included. Not much room to swing a lasso, but it's snug.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { couch: 1 }, numBathrooms: 1 },
    guestPolicy: { maxGuests: 1, maxStayDays: 3, kidsAllowed: false, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "moderate",
    // SpongeBob co-hosts this one (feature 14): he and Sandy are accepted
    // friends, which the rules require. Sign in as sandy to manage the roster, or
    // as spongebob to see it under "Listings you co-host" and edit its details.
    coHostUserIDs: ["seed-host-spongebob"]
  },
  {
    id: "seed-home-squidward-1",
    hostUserID: "seed-host-squidward",
    hostName: "Squidward Tentacles",
    // A host with two listings collides on the "<hostName>'s place" fallback, so
    // both read identically in the request sheet and the chat banner. Every
    // doubled-up host below carries a title to keep the two apart.
    title: "The Clarinet Suite",
    address: { city: "New Orleans", state: "LA", zip: "70116" },
    location: { street: "1132 Royal Street", latitude: 29.9614606, longitude: -90.0615030 },
    description: "A tasteful French Quarter apartment for the discerning guest. Clarinet practice happens nightly, whether you like it or not. Please admire the self-portraits and keep the noise to a civilized minimum.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 2, bedSizes: { king: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 4, kidsAllowed: false, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "strict",
  },
  {
    id: "seed-home-krabs-1",
    hostUserID: "seed-host-krabs",
    hostName: "Eugene Krabs",
    title: "The Room Above the Restaurant",
    address: { city: "Bar Harbor", state: "ME", zip: "04609" },
    location: { street: "7 Newport Drive", latitude: 44.3905728, longitude: -68.2018487 },
    description: "Waterfront anchor-up room above the family restaurant. Wake to the smell of the sea and the sound of a cash register. First guest gets the good mattress, everyone else negotiates. No refunds, money is money.",
    contactPreference: "contactInfo",
    hostContactInfo: "Call the Krusty Krab and ask for Mr. Krabs",
    hostMotivation: "open",
    sleeping: { numGuestRooms: 2, arrangements: { bed: 1, futon: 1 }, numBathrooms: 2, bedSizes: { queen: 1 } },
    guestPolicy: { maxGuests: 3, maxStayDays: 5, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "strict",
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
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1, airMattress: 2 }, numBathrooms: 1, bedSizes: { full: 1 } },
    guestPolicy: { maxGuests: 4, maxStayDays: 3, kidsAllowed: true, guestPetsAllowed: true },
    amenities: cozyAmenities,
    cancellationPolicy: "flexible",
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
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 1, bedSizes: { queen: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 10, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
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
  },
  {
    id: "seed-home-spongebob-2",
    hostUserID: "seed-host-spongebob",
    hostName: "SpongeBob SquarePants",
    title: "The Keys Pineapple",
    address: { city: "Key West", state: "FL", zip: "33040" },
    location: { street: "500 Duval Street", latitude: 24.5556012, longitude: -81.8027503 },
    description: "A second pineapple, this one down in the Keys! Snorkel gear by the door, ukulele on the wall, and Gary visits on weekends. Sunsets included at no extra charge.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "eager",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1, couch: 1 }, numBathrooms: 1, bedSizes: { twin: 1 } },
    guestPolicy: { maxGuests: 3, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: true },
    amenities: cozyAmenities,
    cancellationPolicy: "flexible",
  },
  {
    id: "seed-home-sandy-2",
    hostUserID: "seed-host-sandy",
    hostName: "Sandy Cheeks",
    title: "The Oak Tree Hideout",
    address: { city: "Austin", state: "TX", zip: "78701" },
    location: { street: "600 Congress Avenue", latitude: 30.2684980, longitude: -97.7431110 },
    description: "Downtown Texas hideout for close friends passing through. Backyard oak tree with a rope swing, a workshop full of half-built inventions, and the best barbecue recommendations in town.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 1, bedSizes: { queen: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 5, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "moderate",
    // The middle tier (feature 7). The ACL below is only the first degree, which
    // is all a client could ever compute; `rebuildListingACLs` widens it to the
    // second degree once the functions run. Until then it behaves as friendsOnly,
    // which is the safe direction to be wrong in.
  },
  {
    id: "seed-home-squidward-2",
    hostUserID: "seed-host-squidward",
    hostName: "Squidward Tentacles",
    title: "The Easel Loft",
    address: { city: "Portland", state: "OR", zip: "97205" },
    location: { street: "1219 Southwest Park Avenue", latitude: 45.5165483, longitude: -122.6834106 },
    description: "An artist's retreat beside the museum, for guests who appreciate the finer things. Easels provided. Interpretive dance in common areas is, regrettably, permitted but not encouraged.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "selective",
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 2, bedSizes: { king: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 4, kidsAllowed: false, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "strict",
  },
  {
    id: "seed-home-krabs-2",
    hostUserID: "seed-host-krabs",
    hostName: "Eugene Krabs",
    title: "The Ocean Drive Condo",
    address: { city: "Miami Beach", state: "FL", zip: "33139" },
    location: { street: "1300 Ocean Drive", latitude: 25.7841289, longitude: -80.1301201 },
    description: "South Beach condo with an ocean view worth every penny, and I do mean every penny. Rooftop deck, valet, and a safe I check twice nightly. Treat it well and we will get along famously.",
    contactPreference: "inApp",
    hostContactInfo: null,
    hostMotivation: "open",
    sleeping: { numGuestRooms: 2, arrangements: { bed: 2 }, numBathrooms: 2, bedSizes: { queen: 1, twin: 1 } },
    guestPolicy: { maxGuests: 4, maxStayDays: 6, kidsAllowed: true, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "moderate",
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
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, bedSizes: { full: 1 } },
    guestPolicy: { maxGuests: 2, maxStayDays: 5, kidsAllowed: false, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "moderate",
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
    sleeping: { numGuestRooms: 3, arrangements: { bed: 3 }, numBathrooms: 3, bedSizes: { queen: 2, king: 1 } },
    guestPolicy: { maxGuests: 6, maxStayDays: 4, kidsAllowed: true, guestPetsAllowed: false },
    amenities: cozyAmenities,
    cancellationPolicy: "strict",
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
    sleeping: { numGuestRooms: 1, arrangements: { bed: 1 }, numBathrooms: 1, bedSizes: { queen: 1 } },
    guestPolicy: { maxGuests: 1, maxStayDays: 14, kidsAllowed: true, guestPetsAllowed: false },
    amenities,
    cancellationPolicy: "flexible",
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
  return Timestamp.fromDate(new Date(Date.now() + n * 86_400_000));
}

async function seedUsers() {
  for (const u of users) {
    await auth.createUser({ uid: u.uid, email: u.email, password: castPassword, displayName: u.displayName })
      .catch(async (err) => {
        if (err.code !== "auth/uid-already-exists") throw err;
        // createUser sets a password; it never resets one. Without this, an
        // account that already exists keeps whatever password it was born with
        // forever — which is how the cast went on answering to a committed
        // password in prod. Updating here makes a re-run a rotation.
        await auth.updateUser(u.uid, {
          email: u.email,
          password: castPassword,
          displayName: u.displayName,
        });
      });
    await db.collection("users").doc(u.uid).set({
      displayName: u.displayName,
      // The name-search index the app queries; without it the seeded cast is
      // invisible to friend search (see scripts/search_terms.js).
      searchTerms: searchTerms(u.displayName),
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
  const collections = ["homes", "stayRequests", "friendEdges", "conversations", "messages", "reviews", "references"];
  for (const name of collections) {
    const count = await deleteCollection(name);
    console.log(`Reset: deleted ${count} doc(s) from ${name}.`);
  }
}

// The accepted friends of one user, read from the `friendEdges` array below —
// the seed-side twin of the Cloud Function's acceptedFriendsOf().
function seededFriendsOf(userID) {
  return friendEdges
    .filter((e) => e.status === "accepted" && (e.userA === userID || e.userB === userID))
    .map((e) => (e.userA === userID ? e.userB : e.userA));
}

async function seedHomes() {
  for (const home of homes) {
    const { location, ...publicListing } = home;
    // Friends-only: the ACL is always host + accepted friends, same as
    // rebuildListingACLs writes in production.
    publicListing.allowedViewerIDs = [...new Set([home.hostUserID, ...seededFriendsOf(home.hostUserID)])];
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
    // A completed stay is one that finished; it is what unlocks reviews and what
    // trustStats counts (feature 4). Everything else has no completion time.
    ...(status === "completed" ? { completedAt: now } : {}),
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
      checkInDays: 40, checkOutDays: 42, status: "pending", guestNote: "A king requires the finest suite." }),
    // Finished stays, so the Stays tab has something to review and the profiles
    // have reputations to show. Their dates are in the past, as completion requires.
    stayRequest({ id: "seed-request-completed-patrick-krabs", listingID: "seed-home-krabs-1", guestUserID: "seed-guest-patrick",
      checkInDays: -30, checkOutDays: -27, status: "completed", guestNote: "Is mayonnaise an instrument?", hostNote: "It is not." }),
    stayRequest({ id: "seed-request-completed-sandy-spongebob", listingID: "seed-home-spongebob-1", guestUserID: "seed-host-sandy",
      checkInDays: -20, checkOutDays: -17, status: "completed", guestNote: "Y'all got a spare room?", hostNote: "Always!" }),
    stayRequest({ id: "seed-request-completed-gary-pearl", listingID: "seed-home-pearl-1", guestUserID: "seed-guest-gary",
      checkInDays: -12, checkOutDays: -10, status: "completed", guestNote: "Meow." }),
    // More bookings across more hosts, so every host has at least one taken
    // (accepted or completed) stay somewhere, not just the original core cast.
    stayRequest({ id: "seed-request-patrick-puff", listingID: "seed-home-puff-1", guestUserID: "seed-guest-patrick",
      checkInDays: 25, checkOutDays: 27, status: "accepted", guestNote: "Promise there will be no driving lessons involved.", hostNote: "See that there isn't." }),
    stayRequest({ id: "seed-request-completed-gary-puff", listingID: "seed-home-puff-1", guestUserID: "seed-guest-gary",
      checkInDays: -8, checkOutDays: -6, status: "completed", guestNote: "Meow.", hostNote: "Quiet as a mouse. Lovely guest." }),
    stayRequest({ id: "seed-request-barnacleboy-karen", listingID: "seed-home-karen-1", guestUserID: "seed-guest-barnacleboy",
      checkInDays: 18, checkOutDays: 20, status: "accepted", guestNote: "Does the loft do sarcasm in stereo?", hostNote: "Only in stereo." }),
    stayRequest({ id: "seed-request-squidward-karen", listingID: "seed-home-karen-1", guestUserID: "seed-host-squidward",
      checkInDays: 33, checkOutDays: 35, status: "pending", guestNote: "I appreciate a well-automated space." }),
    stayRequest({ id: "seed-request-gary-mermaidman", listingID: "seed-home-mermaidman-1", guestUserID: "seed-guest-gary",
      checkInDays: 15, checkOutDays: 17, status: "accepted", guestNote: "Meow.", hostNote: "A hero's welcome awaits, citizen snail." }),
    stayRequest({ id: "seed-request-completed-patrick-neptune", listingID: "seed-home-neptune-1", guestUserID: "seed-guest-patrick",
      checkInDays: -15, checkOutDays: -13, status: "completed", guestNote: "Is the trident for swimming or just for looking royal?", hostNote: "Looking royal. Obviously." }),
    stayRequest({ id: "seed-request-karen-plankton", listingID: "seed-home-plankton-1", guestUserID: "seed-host-karen",
      checkInDays: 9, checkOutDays: 10, status: "accepted", guestNote: "Bringing the good soldering iron.", hostNote: "Excellent. We have work to do." }),
    stayRequest({ id: "seed-request-patrick-larry", listingID: "seed-home-larry-1", guestUserID: "seed-guest-patrick",
      checkInDays: 28, checkOutDays: 30, status: "accepted", guestNote: "Do we lift at sunrise or can I sleep in?", hostNote: "Sunrise. No excuses." }),
    stayRequest({ id: "seed-request-larry-krabs2", listingID: "seed-home-krabs-2", guestUserID: "seed-host-larry",
      checkInDays: 45, checkOutDays: 47, status: "pending", guestNote: "Need a beach recovery week after leg day." }),
    stayRequest({ id: "seed-request-larry-sandy2", listingID: "seed-home-sandy-2", guestUserID: "seed-host-larry",
      checkInDays: 22, checkOutDays: 24, status: "accepted", guestNote: "Passing through Austin, mind if I raid the workshop?", hostNote: "Just don't reprogram anything." }),
    stayRequest({ id: "seed-request-completed-neptune-squidward1", listingID: "seed-home-squidward-1", guestUserID: "seed-host-neptune",
      checkInDays: -25, checkOutDays: -23, status: "completed", guestNote: "A king requires impeccable manners, and you delivered.", hostNote: "Naturally." })
];

// Post-stay reviews (feature 1). The document id is "{stayRequestID}_{authorUID}",
// which is what firestore.rules enforces as "one review per person per stay".
// `subjectUserID` is whose profile the review lands on, and whose trustStats the
// `onReviewWritten` trigger recomputes from it.
function review({ stayRequestID, authorUserID, role, rating, publicComment }) {
  const stay = stayRequests.find((r) => r.id === stayRequestID);
  if (!stay) throw new Error(`review references unknown stay ${stayRequestID}`);
  const subjectUserID = role === "guestReviewingHost" ? stay.hostUserID : stay.guestUserID;
  const id = `${stayRequestID}_${authorUserID}`;
  return { id, stayRequestID, listingID: stay.listingID, authorUserID, subjectUserID, role, rating, publicComment,
    createdAt: now, updatedAt: now };
}

const reviews = [
  review({ stayRequestID: "seed-request-completed-patrick-krabs", authorUserID: "seed-guest-patrick",
    role: "guestReviewingHost", rating: 4, publicComment: "Mr. Krabs charged me for the towels but the couch was comfy." }),
  review({ stayRequestID: "seed-request-completed-patrick-krabs", authorUserID: "seed-host-krabs",
    role: "hostReviewingGuest", rating: 3, publicComment: "Ate everything in the fridge. Paid for none of it." }),
  review({ stayRequestID: "seed-request-completed-sandy-spongebob", authorUserID: "seed-host-sandy",
    role: "guestReviewingHost", rating: 5, publicComment: "SpongeBob is the finest host in Bikini Bottom. Spotless pineapple." }),
  review({ stayRequestID: "seed-request-completed-sandy-spongebob", authorUserID: "seed-host-spongebob",
    role: "hostReviewingGuest", rating: 5, publicComment: "Sandy left the place cleaner than she found it!" }),
  review({ stayRequestID: "seed-request-completed-gary-pearl", authorUserID: "seed-guest-gary",
    role: "guestReviewingHost", rating: 5, publicComment: "Meow." }),
  review({ stayRequestID: "seed-request-completed-gary-puff", authorUserID: "seed-guest-gary",
    role: "guestReviewingHost", rating: 5, publicComment: "Meow." }),
  review({ stayRequestID: "seed-request-completed-gary-puff", authorUserID: "seed-host-puff",
    role: "hostReviewingGuest", rating: 5, publicComment: "The quietest guest I have ever hosted. Ten out of ten." }),
  review({ stayRequestID: "seed-request-completed-patrick-neptune", authorUserID: "seed-guest-patrick",
    role: "guestReviewingHost", rating: 5, publicComment: "Got to hold the trident for a whole minute. Best vacation ever." }),
  review({ stayRequestID: "seed-request-completed-patrick-neptune", authorUserID: "seed-host-neptune",
    role: "hostReviewingGuest", rating: 3, publicComment: "Asked about the trident forty times. Otherwise pleasant." }),
  review({ stayRequestID: "seed-request-completed-neptune-squidward1", authorUserID: "seed-host-neptune",
    role: "guestReviewingHost", rating: 5, publicComment: "The self-portraits alone are worth the trip. A cultured host." }),
  review({ stayRequestID: "seed-request-completed-neptune-squidward1", authorUserID: "seed-host-squidward",
    role: "hostReviewingGuest", rating: 5, publicComment: "Finally, a guest who understands the clarinet is not optional listening." })
];

// Friend-written character references (feature 1). One per (subject, author),
// and the rules require an accepted friend edge between the two — which
// seedFriendEdges creates for every pair of seed users.
const references = [
  { id: "seed-host-spongebob_seed-guest-patrick", subjectUserID: "seed-host-spongebob", authorUserID: "seed-guest-patrick",
    text: "SpongeBob is my best friend and he has never once let me down. He also makes breakfast." },
  { id: "seed-host-sandy_seed-host-spongebob", subjectUserID: "seed-host-sandy", authorUserID: "seed-host-spongebob",
    text: "Sandy is the smartest, kindest person I know. You will be safe at her place." },
  { id: "seed-host-krabs_seed-host-pearl", subjectUserID: "seed-host-krabs", authorUserID: "seed-host-pearl",
    text: "He's my dad. He's cheap, but he's honest about it." }
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
//   2. Every listing's allowedViewerIDs is derived from this graph (see
//      seedHomes), so a listing is visible to exactly its host's accepted
//      friends here.
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
    // Backfills edges that completed stays below already required (every stay
    // request needs an accepted friend edge) but that were missing.
    friendEdge("seed-guest-gary", "seed-host-pearl", "accepted", "seed-guest-gary"),
    friendEdge("seed-guest-patrick", "seed-host-krabs", "accepted", "seed-guest-patrick"),
    // More density across the graph, backing the additional stay requests below
    // and giving the previously under-connected hosts (Puff, Karen, Neptune,
    // Mermaid Man on his own listing) guests who can actually book them.
    friendEdge("seed-guest-patrick", "seed-host-puff", "accepted", "seed-guest-patrick"),
    friendEdge("seed-guest-gary", "seed-host-puff", "accepted", "seed-host-puff"),
    friendEdge("seed-guest-barnacleboy", "seed-host-karen", "accepted", "seed-guest-barnacleboy"),
    friendEdge("seed-host-squidward", "seed-host-karen", "accepted", "seed-host-karen"),
    friendEdge("seed-guest-gary", "seed-host-mermaidman", "accepted", "seed-guest-gary"),
    friendEdge("seed-guest-patrick", "seed-host-neptune", "accepted", "seed-host-neptune"),
    friendEdge("seed-guest-patrick", "seed-host-larry", "accepted", "seed-guest-patrick"),
    friendEdge("seed-host-larry", "seed-host-krabs", "accepted", "seed-host-larry"),
    // Pending: Patrick asked Gary (outgoing for Patrick), Neptune asked Krabs,
    // Pearl asked Patrick (incoming for Patrick), Karen asked Mermaid Man,
    // Puff asked Krabs.
    friendEdge("seed-guest-patrick", "seed-guest-gary", "pending", "seed-guest-patrick"),
    friendEdge("seed-host-neptune", "seed-host-krabs", "pending", "seed-host-neptune"),
    friendEdge("seed-host-pearl", "seed-guest-patrick", "pending", "seed-host-pearl"),
    friendEdge("seed-host-karen", "seed-host-mermaidman", "pending", "seed-host-karen"),
    friendEdge("seed-host-puff", "seed-host-krabs", "pending", "seed-host-puff")
];

// S1: each test account (dev, guest-tester) is an accepted friend of every
// other seed user, so both can see every friends-only listing while testing.
// Neither is ever a friend of a real (non-seed) user — that's the whole point
// of replacing anonymous "browse without an account" with a fixed guest
// persona: it's connected only to the SpongeBob cast, never to real people.
const testAccountFriendEdges = TEST_ACCOUNT_UIDS.flatMap((testUID) =>
  users
    .filter((u) => u.uid !== testUID)
    .map((u) => friendEdge(testUID, u.uid, "accepted", testUID))
);

const friendEdges = [...explicitFriendEdges, ...testAccountFriendEdges];

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
    const ts = Timestamp.fromDate(new Date(Date.now() - m.minsAgo * 60_000));
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
  },
  {
    a: "seed-guest-patrick", b: "seed-host-puff", msgs: [
      { from: "seed-guest-patrick", text: "Mrs. Puff! Room for me next month?", minsAgo: 600 },
      { from: "seed-host-puff", text: "Accepted. And no, we are not discussing your license.", minsAgo: 590 },
      { from: "seed-guest-patrick", text: "Wasn't gonna!!", minsAgo: 588 }
    ]
  },
  {
    a: "seed-guest-barnacleboy", b: "seed-host-karen", msgs: [
      { from: "seed-guest-barnacleboy", text: "Heard your loft talks back. Sold.", minsAgo: 250 },
      { from: "seed-host-karen", text: "It does. It also judges your bedtime.", minsAgo: 240 }
    ]
  },
  {
    a: "seed-guest-patrick", b: "seed-host-larry", msgs: [
      { from: "seed-host-larry", text: "Sunrise workout, don't be late, buddy.", minsAgo: 150 },
      { from: "seed-guest-patrick", text: "what if I'm asleep at sunrise", minsAgo: 145 },
      { from: "seed-host-larry", text: "Then we wake you up. See you soon!", minsAgo: 140 }
    ]
  }
];

async function seedConversations() {
  for (const t of conversationThreads) {
    await seedThread(t.a, t.b, t.msgs, t.mutedBy ?? []);
  }
  console.log(`Seeded ${conversationThreads.length} conversation threads.`);
}

async function seedReviews() {
  for (const item of reviews) {
    await db.collection("reviews").doc(item.id).set(item, { merge: true });
  }
  console.log(`Seeded ${reviews.length} reviews.`);
}

async function seedReferences() {
  for (const item of references) {
    await db.collection("references").doc(item.id).set({ ...item, createdAt: now, updatedAt: now }, { merge: true });
  }
  console.log(`Seeded ${references.length} character references.`);
}

// Mirrors `recomputeTrustStats` in functions/src/index.ts. The Cloud Function is
// the source of truth in a deployed project, but it doesn't run against a bare
// emulator, so the seed computes the same numbers from the same documents —
// otherwise every seeded profile shows no reputation at all.
async function seedTrustStats() {
  const MIN_RESPONSES_FOR_RATE = 3;
  for (const user of users) {
    const uid = user.uid;
    const asHost = stayRequests.filter((r) => r.hostUserID === uid);
    const aboutThem = reviews.filter((r) => r.subjectUserID === uid);

    let staysHosted = 0;
    let receivedCount = 0;
    let respondedCount = 0;
    for (const request of asHost) {
      if (request.status === "completed") staysHosted++;
      // A guest-cancelled request was withdrawn, not ignored.
      if (request.status === "cancelled") continue;
      receivedCount++;
      if (request.status !== "pending") respondedCount++;
    }

    const ratings = aboutThem.map((r) => r.rating);
    await db.collection("users").doc(uid).set({
      trustStats: {
        staysHosted,
        staysTaken: stayRequests.filter((r) => r.guestUserID === uid && r.status === "completed").length,
        reviewCount: ratings.length,
        averageRating: ratings.length ? ratings.reduce((sum, r) => sum + r, 0) / ratings.length : null,
        responseRate: receivedCount >= MIN_RESPONSES_FOR_RATE ? respondedCount / receivedCount : null,
        respondedCount,
        receivedCount,
        // Nothing verifies identity yet (feature 3 is unimplemented), so the badge
        // is off for everyone. Flipping one here would be a lie in the demo.
        idVerified: false
      }
    }, { merge: true });
  }
  console.log(`Seeded trust stats for ${users.length} users.`);
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
  await seedReviews();
  await seedReferences();
  // Last: it reads the stay requests and reviews the steps above wrote.
  await seedTrustStats();
  console.log(
    useProd
      ? "Done. The cast now answers to SEED_PROD_PASSWORD; nothing in this repo unlocks them."
      : `Done. Sign in with any seed-*@seed.freebnb.test / ${EMULATOR_PASSWORD} account (or the dev@freebnb.test button in DEBUG builds) to explore.`
  );
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

module.exports = { users, homes, homesByID, stayRequests, reviews, references, friendEdges, conversationThreads };

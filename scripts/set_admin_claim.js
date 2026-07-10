#!/usr/bin/env node
//
// Grants or revokes the `admin` custom claim that firestore.rules' isAdmin()
// checks, which is what lets an account read and triage the `reports` collection
// through the moderation console (feature 6).
//
// The claim can only be minted with Admin SDK credentials, never by the app, so
// a moderator is someone an operator deliberately made one.
//
// Usage:
//   GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json \
//     node scripts/set_admin_claim.js someone@example.com
//   ... --revoke                         to take it away
//   ... --list                           to show current moderators
//
// Against the Auth emulator instead of production:
//   FIRESTORE_EMULATOR_HOST=localhost:8080 \
//   FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 \
//   GCLOUD_PROJECT=freebnb-6814a node scripts/set_admin_claim.js dev@freebnb.test
//
// The user must sign out and back in (or force-refresh their ID token) before a
// changed claim reaches their requests: custom claims ride in the token, and an
// already-issued token keeps its old claims until it expires.

const admin = require("firebase-admin");

admin.initializeApp({
  projectId: process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT,
});

async function listAdmins() {
  let pageToken;
  const admins = [];
  do {
    const result = await admin.auth().listUsers(1000, pageToken);
    for (const user of result.users) {
      if (user.customClaims?.admin === true) admins.push(user.email || user.uid);
    }
    pageToken = result.pageToken;
  } while (pageToken);

  if (admins.length === 0) {
    console.log("No moderators. Grant one with: node scripts/set_admin_claim.js <email>");
  } else {
    console.log(`Moderators (${admins.length}):`);
    for (const who of admins) console.log(`  ${who}`);
  }
}

async function setClaim(email, grant) {
  const user = await admin.auth().getUserByEmail(email);
  // Merge rather than replace: blowing away another claim while adding this one
  // would be a silent, hard-to-trace privilege change.
  const claims = { ...(user.customClaims || {}) };
  if (grant) {
    claims.admin = true;
  } else {
    delete claims.admin;
  }
  await admin.auth().setCustomUserClaims(user.uid, claims);
  console.log(`${grant ? "Granted" : "Revoked"} admin for ${email} (${user.uid}).`);
  console.log("They must sign out and back in before the change takes effect.");
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--list")) return listAdmins();

  const revoke = args.includes("--revoke");
  const email = args.find((a) => !a.startsWith("--"));
  if (!email) {
    console.error("Usage: node scripts/set_admin_claim.js <email> [--revoke] | --list");
    process.exit(1);
  }
  await setClaim(email, !revoke);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});

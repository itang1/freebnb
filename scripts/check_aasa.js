#!/usr/bin/env node
// Refuses to deploy hosting while the apple-app-site-association file still
// carries its Team ID placeholder.
//
// Wired as the hosting predeploy hook in firebase.json, rather than as a test,
// because a placeholder in the repo is a normal state (the Team ID isn't in
// version control) while a placeholder on the live site is not: iOS fetches the
// file once, finds an app ID that matches nothing, and every invite link opens
// Safari from then on, with nothing in any log to say why.
//
// Run directly to check: node scripts/check_aasa.js

const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const AASA_PATH = join(__dirname, "..", "admin", "well-known", "apple-app-site-association.json");
const BUNDLE_ID = "com.poodlestrategy.freebnb";
// Apple Team IDs are ten alphanumeric characters.
const APP_ID = /^[A-Z0-9]{10}\.(.+)$/;

function fail(message) {
  console.error(`\napple-app-site-association: ${message}\n`);
  console.error(`  file: ${AASA_PATH}`);
  console.error("  see:  admin/well-known/README.md\n");
  process.exit(1);
}

let parsed;
try {
  parsed = JSON.parse(readFileSync(AASA_PATH, "utf8"));
} catch (error) {
  fail(`could not be read or parsed: ${error.message}`);
}

const details = parsed?.applinks?.details;
if (!Array.isArray(details) || details.length === 0) {
  fail("has no applinks.details entries");
}

for (const detail of details) {
  const appIDs = detail.appIDs ?? (detail.appID ? [detail.appID] : []);
  if (appIDs.length === 0) fail("has a details entry with no appIDs");

  for (const appID of appIDs) {
    const match = APP_ID.exec(appID);
    if (!match) {
      fail(
        `appID ${JSON.stringify(appID)} is not TEAMID.bundleID with a ten-character Team ID. ` +
          "Paste the real Apple Developer Team ID in place of the placeholder."
      );
    }
    if (match[1] !== BUNDLE_ID) {
      fail(`appID ${JSON.stringify(appID)} does not end in ${BUNDLE_ID}`);
    }
  }
}

console.log("apple-app-site-association: Team ID and bundle id look deployable.");

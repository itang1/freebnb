// Shared setup for the emulator-backed Cloud Functions tests.
//
// Each test file calls `setup(projectID)` with its own project id, so files that
// node --test runs in parallel never share Firestore data. The functions under
// test are the compiled ones in lib/ (run `npm run build` first) and are invoked
// directly through firebase-functions-test's `wrap`, so no Functions emulator is
// involved and triggers never fire on their own: each test calls exactly the
// function it means to.
//
// Storage and FCM have no emulator in this job, so both are replaced with
// recorders before lib/index.js loads. Everything else goes to the Firestore
// emulator, and setup() refuses to run without one so a stray run can't touch a
// real project.
const assert = require("node:assert/strict");

function setup(projectID) {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  if (!host) {
    throw new Error(
      "FIRESTORE_EMULATOR_HOST is not set. Run these through `firebase emulators:exec` (see test/README.md)."
    );
  }

  process.env.GCLOUD_PROJECT = projectID;
  const fft = require("firebase-functions-test")({
    projectId: projectID,
    storageBucket: `${projectID}.appspot.com`,
  });

  const admin = require("firebase-admin");
  const deletedStoragePrefixes = [];
  const pushes = [];
  // The namespace exposes these as prototype getters, so an own property shadows them.
  Object.defineProperty(admin, "storage", {
    configurable: true,
    value: () => ({
      bucket: () => ({
        deleteFiles: async ({ prefix }) => {
          deletedStoragePrefixes.push(prefix);
        },
      }),
    }),
  });
  Object.defineProperty(admin, "messaging", {
    configurable: true,
    value: () => ({
      send: async (message) => {
        pushes.push(message);
        return "test-message-id";
      },
    }),
  });

  const functions = require("../lib/index.js");
  const db = admin.firestore();
  const { Timestamp } = admin.firestore;

  async function reset() {
    deletedStoragePrefixes.length = 0;
    pushes.length = 0;
    const res = await fetch(
      `http://${host}/emulator/v1/projects/${projectID}/databases/(default)/documents`,
      { method: "DELETE" }
    );
    assert.equal(res.status, 200, `clearing the emulator failed: ${res.status}`);
  }

  // A signed-in, non-anonymous caller: what requireFullMember lets through.
  function callAs(uid, data) {
    return { data, auth: { uid, token: { uid, firebase: { sign_in_provider: "password" } } } };
  }

  const DAY = 24 * 60 * 60 * 1000;
  // Midnight UTC `n` days from now, so stays land on whole days like the app's.
  function daysFromNow(n) {
    const today = new Date();
    today.setUTCHours(0, 0, 0, 0);
    return Timestamp.fromMillis(today.getTime() + n * DAY);
  }

  return {
    fft,
    admin,
    db,
    functions,
    Timestamp,
    reset,
    callAs,
    daysFromNow,
    deletedStoragePrefixes,
    pushes,
  };
}

// Asserts `promise` rejects with an HttpsError carrying `code`.
async function rejectsWithCode(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code, `expected ${code}, got ${err.code}: ${err.message}`);
    return true;
  });
}

module.exports = { setup, rejectsWithCode };

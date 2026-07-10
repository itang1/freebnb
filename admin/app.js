// FreeBNB moderation console (feature 6).
//
// A triage queue over the `reports` collection. It holds no privileges of its
// own: every read and write goes through `firestore.rules`, which admits only an
// account carrying the `admin` custom claim (see scripts/set_admin_claim.js).
// Serving this page to the wrong person therefore leaks nothing — Firestore
// simply refuses them. That is the point of putting the check in the rules
// rather than in this file.
//
// No build step and no bundler: ES modules straight from the CDN, so the console
// is a directory of three files that Firebase Hosting serves as-is.

import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, signInWithPopup, GoogleAuthProvider, signOut, onAuthStateChanged, connectAuthEmulator,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getFirestore, collection, query, where, orderBy, limit, onSnapshot,
  doc, updateDoc, serverTimestamp, connectFirestoreEmulator,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

import { firebaseConfig, useEmulators } from "./firebase-config.js";

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

if (useEmulators) {
  connectAuthEmulator(auth, "http://localhost:9099", { disableWarnings: true });
  connectFirestoreEmulator(db, "localhost", 8080);
}

const STATUSES = ["new", "reviewing", "actioned", "dismissed"];
const QUEUE_LIMIT = 100;

const el = (id) => document.getElementById(id);
const gate = el("gate");
const gateError = el("gate-error");
const consoleEl = el("console");
const session = el("session");
const reportsList = el("reports");
const loading = el("loading");
const empty = el("empty");

let activeStatus = "new";
let unsubscribe = null;

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

el("sign-in").addEventListener("click", async () => {
  gateError.hidden = true;
  try {
    await signInWithPopup(auth, new GoogleAuthProvider());
  } catch (error) {
    showGateError(error.message);
  }
});

el("sign-out").addEventListener("click", () => signOut(auth));

onAuthStateChanged(auth, (user) => {
  if (!user) {
    teardown();
    gate.hidden = false;
    consoleEl.hidden = true;
    session.hidden = true;
    return;
  }
  el("who").textContent = user.email ?? user.uid;
  session.hidden = false;
  gate.hidden = true;
  consoleEl.hidden = false;
  subscribe(activeStatus);
});

function showGateError(message) {
  gateError.textContent = message;
  gateError.hidden = false;
}

// ---------------------------------------------------------------------------
// Queue
// ---------------------------------------------------------------------------

for (const button of document.querySelectorAll("#filters button")) {
  button.addEventListener("click", () => {
    activeStatus = button.dataset.status;
    for (const other of document.querySelectorAll("#filters button")) {
      other.classList.toggle("active", other === button);
    }
    subscribe(activeStatus);
  });
}

function teardown() {
  if (unsubscribe) unsubscribe();
  unsubscribe = null;
  reportsList.replaceChildren();
}

function subscribe(status) {
  teardown();
  loading.hidden = false;
  empty.hidden = true;

  const q = query(
    collection(db, "reports"),
    where("status", "==", status),
    orderBy("createdAt", "desc"),
    limit(QUEUE_LIMIT)
  );

  unsubscribe = onSnapshot(
    q,
    (snapshot) => {
      loading.hidden = true;
      empty.hidden = snapshot.size > 0;
      reportsList.replaceChildren(...snapshot.docs.map(renderReport));
    },
    (error) => {
      loading.hidden = true;
      // The overwhelmingly likely cause is a signed-in account without the
      // `admin` claim, so say that rather than echoing "Missing or insufficient
      // permissions" and leaving the moderator to guess.
      teardown();
      consoleEl.hidden = true;
      gate.hidden = false;
      showGateError(
        error.code === "permission-denied"
          ? "That account isn't a moderator. Grant it with: node scripts/set_admin_claim.js <email> — then sign out and back in."
          : error.message
      );
    }
  );
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function renderReport(snapshot) {
  const data = snapshot.data();
  const item = document.createElement("li");
  item.className = "report";

  const title = document.createElement("h2");
  title.textContent = `${data.targetType} · ${data.targetID}`;
  item.append(title);

  const meta = document.createElement("div");
  meta.className = "meta";
  meta.append(
    span(`Reported by ${data.reporterUserID}`),
    span(formatDate(data.createdAt)),
    badge(data.source === "auto" ? "auto-flagged" : "user report", data.source === "auto")
  );
  item.append(meta);

  const reason = document.createElement("p");
  reason.className = "reason";
  reason.textContent = data.reason ?? "";
  item.append(reason);

  if (data.moderatorNote) {
    const note = document.createElement("p");
    note.className = "meta";
    note.textContent = `Note: ${data.moderatorNote}`;
    item.append(note);
  }

  const noteField = document.createElement("textarea");
  noteField.placeholder = "Moderator note (optional)";
  noteField.value = data.moderatorNote ?? "";
  item.append(noteField);

  const actions = document.createElement("div");
  actions.className = "actions";
  // Only offer the states this report isn't already in. A "mark new" button on a
  // new report is noise, and a mis-click that re-opens a resolved case is worse.
  for (const status of STATUSES.filter((s) => s !== data.status)) {
    const button = document.createElement("button");
    button.textContent = label(status);
    if (status === "actioned") button.classList.add("danger");
    button.addEventListener("click", () => triage(snapshot.id, status, noteField.value, item));
    actions.append(button);
  }
  item.append(actions);

  return item;
}

async function triage(reportID, status, note, item) {
  for (const button of item.querySelectorAll("button")) button.disabled = true;
  const trimmed = note.trim();
  try {
    // The rules pin this to exactly these four keys and to `reviewedBy` being the
    // caller, so nothing here can rewrite what was reported or by whom.
    await updateDoc(doc(db, "reports", reportID), {
      status,
      ...(trimmed ? { moderatorNote: trimmed } : {}),
      reviewedBy: auth.currentUser.uid,
      reviewedAt: serverTimestamp(),
    });
    // The snapshot listener drops the row from this queue on its own.
  } catch (error) {
    for (const button of item.querySelectorAll("button")) button.disabled = false;
    const failure = document.createElement("p");
    failure.className = "error";
    failure.textContent = error.message;
    item.append(failure);
  }
}

const label = (status) => ({
  new: "Reopen",
  reviewing: "Start reviewing",
  actioned: "Action",
  dismissed: "Dismiss",
}[status]);

function span(text) {
  const node = document.createElement("span");
  node.textContent = text;
  return node;
}

function badge(text, isAuto) {
  const node = document.createElement("span");
  node.className = isAuto ? "badge auto" : "badge";
  node.textContent = text;
  return node;
}

function formatDate(timestamp) {
  if (!timestamp?.toDate) return "just now";
  return timestamp.toDate().toLocaleString();
}

#!/usr/bin/env bash
#
# dev_emulator.sh — one-touch local backend for FreeBNB.
#
# Boots the Firebase Local Emulator Suite (Auth + Firestore, plus Functions when
# they build) and seeds the SpongeBob demo data. That demo data includes the two
# accounts behind the DEBUG-only "Sign in as devna" / "Sign in as guest" buttons
# on the welcome screen, so after this runs those buttons work without ever
# needing Sign in with Apple.
#
# The freebnb scheme runs this automatically as a build pre-action every time you
# press Run in Xcode, so normally you never call it by hand. It is also safe to
# run directly in a Terminal:
#
#     ./scripts/dev_emulator.sh
#
# Idempotent: if the emulator is already up it leaves your current data alone
# (so listings you created while clicking around survive a re-run) and exits.
# Only a cold start seeds fresh demo data.

set -euo pipefail

# Xcode build pre-actions run under /bin/sh with a bare PATH. Re-add the tools
# this script needs: firebase (Homebrew/npm global), java (Firestore emulator),
# and node — which nvm installs outside the standard prefixes.
export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk/bin:/usr/bin:/bin:${PATH:-}"
for nbin in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$nbin" ] && PATH="$nbin:$PATH"
done
export PATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AUTH_PORT=9099
FIRESTORE_PORT=8080
PROJECT=freebnb-6814a
LOG_DIR="$REPO_ROOT/.emulator"
# Firestore export/import lives here so hand-created data survives a clean
# emulator restart (see --export-on-exit / --import below). Gitignored.
DATA_DIR="$LOG_DIR/data"
mkdir -p "$LOG_DIR"

emulator_up() { curl -sf "http://localhost:${AUTH_PORT}/" >/dev/null 2>&1; }

# True when the demo data is present. Probes a seed *listing* with the emulator's
# "owner" bypass so it works regardless of Firestore rules. This is what lets a
# re-run *heal* an emulator that came up empty, rather than trusting "the port is
# open" to mean "the data is there" (which is exactly how a crashed seed used to
# leave the app with nothing to show).
#
# The sentinel is a seed-only listing, never a user doc: the running app rewrites
# the signed-in user's own profile on launch, so users/seed-dev-tester can exist
# on an otherwise-empty emulator and would give a false positive.
is_seeded() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer owner' \
      "http://localhost:${FIRESTORE_PORT}/v1/projects/${PROJECT}/databases/(default)/documents/homes/seed-home-spongebob-1")" = "200" ]
}

seed() {
  echo "Seeding demo data (Devna, Guesta, and the SpongeBob cast)…"
  node scripts/seed_test_data.js --reset
}

if emulator_up; then
  if is_seeded; then
    echo "Firebase emulator already running and seeded — leaving your data in place."
  else
    echo "Emulator is running but has no demo data — seeding it now…"
    seed
  fi
  echo "Ready. The 'Sign in as devna' / 'Sign in as guest' buttons are live."
  exit 0
fi

echo "Starting Firebase emulators…"

# The seed script and the Functions runtime both need firebase-admin from
# functions/node_modules.
if [ ! -d "$REPO_ROOT/functions/node_modules" ]; then
  echo "Installing functions dependencies (first run only)…"
  (cd functions && npm install)
fi

# Functions are optional for the sign-in buttons; include them only if the
# TypeScript compiles, so a functions build error can't block local sign-in.
EMULATORS="auth,firestore"
if (cd functions && npm run build) >"$LOG_DIR/functions-build.log" 2>&1; then
  EMULATORS="auth,firestore,functions"
else
  echo "Functions did not build; starting without them (see .emulator/functions-build.log)."
fi

# Persist data across restarts: export on a clean shutdown, and re-import it on
# the next cold start. --import only accepts an existing export, so pass it only
# when one is there (the first ever run has none).
IMPORT_ARGS=()
if [ -d "$DATA_DIR" ]; then
  IMPORT_ARGS=(--import "$DATA_DIR")
fi

nohup firebase emulators:start \
  --only "$EMULATORS" \
  --project "$PROJECT" \
  --export-on-exit "$DATA_DIR" \
  ${IMPORT_ARGS[@]+"${IMPORT_ARGS[@]}"} \
  >"$LOG_DIR/emulators.log" 2>&1 &
echo $! >"$LOG_DIR/emulators.pid"

# Wait up to ~60s for the Auth emulator to answer before seeding.
for _ in $(seq 1 60); do
  emulator_up && break
  sleep 1
done

if ! emulator_up; then
  echo "Emulator did not become ready in time; check $LOG_DIR/emulators.log" >&2
  exit 1
fi

# A restored export already has the demo data; only a truly empty start needs a
# seed. Either way the app ends up with data — no manual re-run required.
if is_seeded; then
  echo "Restored demo data from the previous session."
else
  seed
fi

echo "Ready. The 'Sign in as devna' / 'Sign in as guest' buttons are now live."

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
LOG_DIR="$REPO_ROOT/.emulator"
mkdir -p "$LOG_DIR"

emulator_up() { curl -sf "http://localhost:${AUTH_PORT}/" >/dev/null 2>&1; }

if emulator_up; then
  echo "Firebase emulator already running — leaving existing data in place."
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

nohup firebase emulators:start \
  --only "$EMULATORS" \
  --project freebnb-6814a \
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

echo "Seeding demo data (Devna, Guesta, and the SpongeBob cast)…"
node scripts/seed_test_data.js --reset

echo "Ready. The 'Sign in as devna' / 'Sign in as guest' buttons are now live."

#!/bin/bash
# Copies the right GoogleService-Info.plist into the app bundle before
# sources compile. Add this as a Run Script phase in Xcode *before* the
# "Compile Sources" phase (Build Phases → + → New Run Script Phase).
#
# Place env-specific plists here:
#   Config/GoogleService-Info.Debug.plist    — dev/staging Firebase project
#   Config/GoogleService-Info.Release.plist  — production Firebase project
#
# If the env-specific plist is absent the script falls back to the
# checked-in freebnb/GoogleService-Info.plist so the build still succeeds.

set -euo pipefail

DEST="${SRCROOT}/freebnb/GoogleService-Info.plist"

if [ "${CONFIGURATION}" = "Debug" ]; then
    CANDIDATE="${SRCROOT}/Config/GoogleService-Info.Debug.plist"
else
    CANDIDATE="${SRCROOT}/Config/GoogleService-Info.Release.plist"
fi

if [ -f "${CANDIDATE}" ]; then
    cp "${CANDIDATE}" "${DEST}"
    echo "note: [select_google_services] copied $(basename "${CANDIDATE}") → GoogleService-Info.plist"
else
    echo "note: [select_google_services] ${CANDIDATE} not found — using checked-in plist"
fi

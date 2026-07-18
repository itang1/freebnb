#!/bin/bash
# Copies the right GoogleService-Info.plist into the app bundle before
# sources compile. Add this as a Run Script phase in Xcode *before* the
# "Compile Sources" phase (Build Phases → + → New Run Script Phase).
#
# Place env-specific plists here:
#   config/GoogleService-Info.Debug.plist    — dev/staging Firebase project
#   config/GoogleService-Info.Release.plist  — production Firebase project
#
# If the env-specific plist is absent the script falls back to the
# checked-in freebnb/GoogleService-Info.plist so the build still succeeds.
#
# The build phase lists only this script as an input file so a no-change
# build can skip the phase entirely. If you add the env-specific plists
# above, also add them to the phase's Input Files in Xcode so edits to
# them re-trigger the copy.

set -euo pipefail

DEST="${SRCROOT}/freebnb/GoogleService-Info.plist"

if [ "${CONFIGURATION}" = "Debug" ]; then
    CANDIDATE="${SRCROOT}/config/GoogleService-Info.Debug.plist"
else
    CANDIDATE="${SRCROOT}/config/GoogleService-Info.Release.plist"
fi

if [ -f "${CANDIDATE}" ]; then
    cp "${CANDIDATE}" "${DEST}"
    echo "note: [select_google_services] copied $(basename "${CANDIDATE}") → GoogleService-Info.plist"
else
    echo "note: [select_google_services] ${CANDIDATE} not found — using checked-in plist"
fi

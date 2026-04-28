#!/usr/bin/env bash
# Increments CFBundleVersion (build number) in the app's Info.plist.
# Run before each TestFlight or App Store upload.
#
# Usage: ./scripts/bump_build.sh
#        ./scripts/bump_build.sh --set 42   (set to a specific value)
#
# The marketing version (CFBundleShortVersionString) is managed manually in Xcode.

set -euo pipefail

PLIST="freebnb/Info.plist"

if [ ! -f "$PLIST" ]; then
  # Xcode 14+ stores version in the project file rather than an Info.plist.
  # In that case use agvtool instead:
  #   agvtool next-version -all
  echo "Info.plist not found at $PLIST — use 'agvtool next-version -all' instead." >&2
  exit 1
fi

current=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")

if [[ "${1:-}" == "--set" && -n "${2:-}" ]]; then
  new="$2"
else
  new=$((current + 1))
fi

/usr/libexec/PlistBuddy -c "Set CFBundleVersion $new" "$PLIST"
echo "Build number: $current → $new"

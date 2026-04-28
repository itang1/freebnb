#!/usr/bin/env bash
# Increments CFBundleVersion (CURRENT_PROJECT_VERSION) across all targets.
# This project uses GENERATE_INFOPLIST_FILE=YES so the version lives in
# project.pbxproj, not Info.plist. agvtool handles that correctly.
#
# Usage:
#   ./scripts/bump_build.sh           -- increment by 1
#   ./scripts/bump_build.sh --set 42  -- set to a specific number
#
# Run from the repo root. The marketing version (MARKETING_VERSION /
# CFBundleShortVersionString) is managed separately with bump_version.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--set" && -n "${2:-}" ]]; then
  agvtool new-version -all "$2"
else
  agvtool next-version -all
fi

echo "Build number updated. Current: $(agvtool what-version -terse)"

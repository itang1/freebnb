#!/usr/bin/env bash
# Sets the marketing version (CFBundleShortVersionString / MARKETING_VERSION).
#
# Usage:
#   ./scripts/bump_version.sh 1.1.0
#
# Run from the repo root. Also bumps the build number so every submission
# has a unique (marketing version, build number) pair.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  (e.g. $0 1.1.0)" >&2
  exit 1
fi

agvtool new-marketing-version "$VERSION"
agvtool next-version -all

echo "Version: $VERSION  Build: $(agvtool what-version -terse)"

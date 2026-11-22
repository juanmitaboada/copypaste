#!/usr/bin/env bash
# Fails unless VERSION, the README version badge, the latest CHANGELOG release and the
# app's VERSION constant (shown in the page footer) agree.
# Run by CI; run it locally before tagging a release.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION is not semver: '$version'" >&2; exit 1; }

badge="$(sed -n 's|.*img.shields.io/badge/version-\([0-9.]*\)-.*|\1|p' README.md | head -1)"
changelog="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
app="$(sed -n "s/^const VERSION = '\([^']*\)';$/\\1/p" app/src/lib.php)"
link="$(sed -n "s|^\[${version//./\\.}\]: .*/releases/tag/v\(.*\)$|\1|p" CHANGELOG.md)"

status=0
check() { if [[ "$2" == "$version" ]]; then echo "ok   $1: $2"; else echo "FAIL $1: '$2' (VERSION is $version)"; status=1; fi; }
check "README badge" "$badge"
check "latest CHANGELOG release" "$changelog"
check "CHANGELOG release link" "$link"
check "app VERSION constant (footer)" "$app"
exit "$status"

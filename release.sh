#!/bin/bash
#
# Publish a new Isle release in one go:
#   ./release.sh 1.3.11 "What changed, in a sentence or two"
#
# Bumps the version, runs the tests, builds, zips, SIGNS the zip (the in-app updater refuses unsigned releases),
# commits and pushes everything, creates the GitHub release with the zip and its .sig, then updates the Homebrew tap.
# Needs: gh (signed in), the signing key at ~/.isle/update-signing.key, and ~/homebrew-isle.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"; NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -n "$NOTES" ]] || { echo "usage: ./release.sh <x.y.z> \"release notes\""; exit 1; }
KEY="${ISLE_SIGNING_KEY:-$HOME/.isle/update-signing.key}"
[[ -f "$KEY" ]] || { echo "Missing signing key: $KEY (swift sign-update.swift keygen \"$KEY\")"; exit 1; }
[[ -d "$HOME/homebrew-isle" ]] || { echo "Missing ~/homebrew-isle"; exit 1; }
if gh release view "v$VERSION" >/dev/null 2>&1; then echo "v$VERSION already exists"; exit 1; fi

OLD="$(grep -E '^VERSION=' build.sh | cut -d'"' -f2)"
sed -i '' "s/\"$OLD\"/\"$VERSION\"/" Sources/IsleCore/SettingsKeys.swift build.sh

echo "==> Tests"
./build.sh --test 2>&1 | tee "${TMPDIR:-/tmp}/isle-release-test.log" | grep -E "error:|Executed [0-9]+ tests" | tail -2
grep -q "0 failures" "${TMPDIR:-/tmp}/isle-release-test.log" || { echo "Tests failed; not releasing."; exit 1; }

echo "==> Build, zip, sign"
./build.sh 2>&1 | grep -E "error:|Built"
mkdir -p dist
ZIP="dist/Isle-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/Isle.app "$ZIP"
swift sign-update.swift sign "$KEY" "$ZIP"

echo "==> Commit, push, release"
git add -A
git commit -q -m "Release $VERSION" -m "$NOTES"
git push -q
gh release create "v$VERSION" "$ZIP" "$ZIP.sig" -t "Isle $VERSION" -n "$NOTES"

echo "==> Homebrew tap"
( cd "$HOME/homebrew-isle" && ./update.sh "$VERSION" | tail -1 && git commit -qam "isle $VERSION" && git push -q )
echo "✅ Isle $VERSION is out."

#!/bin/bash
# CI-only, sequential host verification then ARM packaging. Never runs ARM on Intel.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'ARM cross-build is CI-only' >&2
  exit 2
fi
if [[ "$(/usr/bin/uname -m)" != x86_64 ]]; then
  echo 'ARM cross-build requires the verified Intel host' >&2
  exit 2
fi
cd "$(dirname "$0")/.."
PARROT_CROSS_SOURCE="$(git rev-parse HEAD)"
test "$(cat build-evidence/source-commit.txt)" = "$PARROT_CROSS_SOURCE"
test "$(cat build-evidence/architecture.txt)" = x86_64
test "$(tail -n 1 build-evidence/profile-test.log)" = 'ALL PASS'
test "$(/usr/bin/lipo -archs dist/Parrot.app/Contents/MacOS/Parrot)" = x86_64
test -f Parrot-local-candidate.zip
test ! -e .parrot-host-evidence
test ! -e build-evidence/host-x86_64
test ! -e Parrot-arm64-build-only.zip
mv build-evidence .parrot-host-evidence
mkdir build-evidence
mv .parrot-host-evidence build-evidence/host-x86_64
mv Parrot-local-candidate.zip build-evidence/host-x86_64/Parrot-host-x86_64-test-only.zip

# Use exactly the same target flags for path resolution and Makefile compilation.
PARROT_CROSS_FLAGS=(--arch arm64 --scratch-path .build/arm64-cross
  --force-resolved-versions --disable-keychain --disable-netrc)
PARROT_CROSS_BINDIR="$(swift build -c release "${PARROT_CROSS_FLAGS[@]}" --show-bin-path)"
case "$PARROT_CROSS_BINDIR" in
  "$PWD/.build/arm64-cross/"*) ;;
  *) echo 'Unexpected ARM bin path' >&2; exit 2 ;;
esac
make bundle CONFIG=release SIGN_IDENTITY=- VERSION=0.29.7-local-test \
  BINDIR="$PARROT_CROSS_BINDIR" \
  SWIFT_BUILD_FLAGS='--arch arm64 --scratch-path .build/arm64-cross --force-resolved-versions --disable-keychain --disable-netrc' \
  2>&1 | tee build-evidence/arm64-cross-build.log
test "$(git rev-parse HEAD)" = "$PARROT_CROSS_SOURCE"
git diff --exit-code
python3 -B scripts/prepare-arm-cross-candidate.py | tee build-evidence/arm64-prepare.log
codesign --force --options runtime --timestamp=none \
  --entitlements build-evidence/arm64-target/test-entitlements.plist \
  --sign - dist/Parrot.app
ditto -c -k --keepParent dist/Parrot.app Parrot-arm64-build-only.zip
python3 -B scripts/prepare-arm-cross-candidate.py --finalize | tee build-evidence/arm64-finalize.log

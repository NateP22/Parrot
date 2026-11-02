#!/bin/bash
# CI-only setup artifact. No Intel app execution and no full-profile PASS claims.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'ARM setup build is CI-only' >&2; exit 2
fi
test "$(/usr/bin/uname -m)" = x86_64
test "$(xcrun --sdk macosx --show-sdk-version)" = 26.5
cd "$(dirname "$0")/.."
PARROT_SETUP_SOURCE="$(git rev-parse HEAD)"
git diff HEAD --exit-code
test ! -e build-evidence
test ! -e Parrot-arm64-setup-only.zip
mkdir build-evidence
swift --version | tee build-evidence/toolchain.txt
xcodebuild -version | tee -a build-evidence/toolchain.txt
for PARROT_FOCUSED_TEST in test-arm-setup-candidate.py test-arm-cross-candidate.py test-keychain-store.py \
 test-qa-credential-admission.py test-qa-window-reopen.py test-native-credential-probe.py \
 test-native-credential-runner.py test-selector-credential-policy.py test-qa-bundle-policy.py test-native-answer-qualification.py \
 test-microphone-input.sh; do
  case "$PARROT_FOCUSED_TEST" in
    *.py) python3 -B "scripts/$PARROT_FOCUSED_TEST" 2>&1 | tee "build-evidence/$PARROT_FOCUSED_TEST.log" ;;
    *.sh) bash "scripts/$PARROT_FOCUSED_TEST" 2>&1 | tee "build-evidence/$PARROT_FOCUSED_TEST.log" ;;
    *) exit 2 ;;
  esac
  printf '%s\n' "$PARROT_FOCUSED_TEST" >> build-evidence/focused-passed.txt
done
PARROT_SETUP_FLAGS=(--arch arm64 --scratch-path .build/arm64-setup-only
 --force-resolved-versions --disable-keychain --disable-netrc)
PARROT_SETUP_BINDIR="$(swift build -c release "${PARROT_SETUP_FLAGS[@]}" --show-bin-path)"
case "$PARROT_SETUP_BINDIR" in "$PWD/.build/arm64-setup-only/"*) ;; *) exit 2 ;; esac
make bundle CONFIG=release SIGN_IDENTITY=- VERSION=0.29.7-local-test \
 BINDIR="$PARROT_SETUP_BINDIR" \
 SWIFT_BUILD_FLAGS='--arch arm64 --scratch-path .build/arm64-setup-only --force-resolved-versions --disable-keychain --disable-netrc' \
 2>&1 | tee build-evidence/arm64-setup-build.log
test "$(git rev-parse HEAD)" = "$PARROT_SETUP_SOURCE"
git diff HEAD --exit-code
python3 -B scripts/prepare-arm-setup-candidate.py | tee build-evidence/arm64-setup-prepare.log
codesign --force --options runtime --timestamp=none \
 --entitlements build-evidence/arm64-setup/test-entitlements.plist --sign - dist/Parrot.app
ditto -c -k --keepParent dist/Parrot.app Parrot-arm64-setup-only.zip
python3 -B scripts/prepare-arm-setup-candidate.py --finalize | tee build-evidence/arm64-setup-finalize.log

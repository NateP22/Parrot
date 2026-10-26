#!/bin/bash
# Build on a Mac with full Xcode. No signing secrets or real API keys required.
set -euo pipefail
mkdir -p build-evidence
swift --version | tee build-evidence/toolchain.txt
xcodebuild -version | tee -a build-evidence/toolchain.txt
python3 scripts/test-keychain-store.py | tee build-evidence/credentials.log
make build CONFIG=release SWIFT_BUILD_FLAGS="--force-resolved-versions --disable-keychain --disable-netrc"
.build/release/Parrot --profile-test > build-evidence/profile-test.log 2>&1
tail -1 build-evidence/profile-test.log
make bundle CONFIG=release SIGN_IDENTITY=- VERSION=0.29.7-local-test \
  SWIFT_BUILD_FLAGS="--force-resolved-versions --disable-keychain --disable-netrc"

python3 - <<'PY'
from pathlib import Path
import plistlib
app = Path('dist/Parrot.app')
info = app / 'Contents/Info.plist'
p = plistlib.loads(info.read_bytes())
p['ParrotKeychainService'] = 'com.uygar.parrot.local-test'
p['ParrotSessionOnlyCredentials'] = True
p['SUEnableAutomaticChecks'] = False
p['SUAutomaticallyUpdate'] = False
p.pop('SUFeedURL', None)
info.write_bytes(plistlib.dumps(p))
e = plistlib.loads(Path('Parrot/Parrot.entitlements').read_bytes())
# The local test bundle is ad-hoc signed, so it and its bundled, verified
# Sparkle framework have no Team ID. Keep other hardened-runtime controls.
e['com.apple.security.cs.disable-library-validation'] = True
Path('build-evidence/test-entitlements.plist').write_bytes(plistlib.dumps(e))
assert p['ParrotSessionOnlyCredentials'] and 'SUFeedURL' not in p
PY
codesign --force --options runtime --timestamp=none \
  --entitlements build-evidence/test-entitlements.plist --sign - dist/Parrot.app
codesign --verify --deep --strict dist/Parrot.app
xcrun vtool -show-build dist/Parrot.app/Contents/MacOS/Parrot | tee build-evidence/macho-build.txt
git rev-parse HEAD > build-evidence/source-commit.txt
shasum -a 256 dist/Parrot.app/Contents/MacOS/Parrot > build-evidence/binary.sha256
ditto -c -k --keepParent dist/Parrot.app Parrot-local-candidate.zip
shasum -a 256 Parrot-local-candidate.zip > build-evidence/archive.sha256

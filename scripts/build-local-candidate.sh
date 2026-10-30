#!/bin/bash
# Build on a Mac with full Xcode. No signing secrets or real API keys required.
set -euo pipefail
mkdir -p build-evidence
swift --version | tee build-evidence/toolchain.txt
xcodebuild -version | tee -a build-evidence/toolchain.txt
python3 scripts/test-keychain-store.py | tee build-evidence/credentials.log
python3 scripts/test-qa-bundle-policy.py 2>&1 | tee build-evidence/qa-bundle-policy.log
python3 scripts/test-native-answer-qualification.py 2>&1 | tee build-evidence/native-answer-qualification.log
bash scripts/test-microphone-input.sh | tee build-evidence/microphone-format.log
make build CONFIG=release SWIFT_BUILD_FLAGS="--force-resolved-versions --disable-keychain --disable-netrc"
.build/release/Parrot --profile-test > build-evidence/profile-test.log 2>&1
tail -1 build-evidence/profile-test.log
make bundle CONFIG=release SIGN_IDENTITY=- VERSION=0.29.7-local-test \
  SWIFT_BUILD_FLAGS="--force-resolved-versions --disable-keychain --disable-netrc"

python3 - <<'PY'
from pathlib import Path
import plistlib
import subprocess
app = Path('dist/Parrot.app')
info = app / 'Contents/Info.plist'
p = plistlib.loads(info.read_bytes())
# Keep one isolated QA container and credential service across relaunches.
# Ad-hoc signing still changes its code requirement: this does NOT assert that
# an update inherits Keychain access or macOS permissions. Verify those on the
# installed candidate; never relax its requirement or the original app's ACL.
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
architecture = subprocess.check_output(['uname', '-m'], text=True).strip()
assert architecture in ('arm64', 'x86_64'), 'Unsupported build host architecture'
test_id = 'com.uygar.parrot.sat54.qa'
p['CFBundleIdentifier'] = test_id
p['CFBundleName'] = 'Parrot SAT54 QA'
p['CFBundleDisplayName'] = 'Parrot SAT54 QA'
p['ParrotSourceCommit'] = commit
p['ParrotBuildArchitecture'] = architecture
p['ParrotKeychainService'] = test_id
p['ParrotSessionOnlyCredentials'] = False
p['ParrotNativeAnswerTrace'] = True
p['ParrotQASetupByDefault'] = True
p['SUEnableAutomaticChecks'] = False
p['SUAutomaticallyUpdate'] = False
p.pop('SUFeedURL', None)
info.write_bytes(plistlib.dumps(p))
e = plistlib.loads(Path('Parrot/Parrot.entitlements').read_bytes())
# The local test bundle is ad-hoc signed, so it and its bundled, verified
# Sparkle framework have no Team ID. Keep other hardened-runtime controls.
e['com.apple.security.cs.disable-library-validation'] = True
Path('build-evidence/test-entitlements.plist').write_bytes(plistlib.dumps(e))
assert not p['ParrotSessionOnlyCredentials'] and 'SUFeedURL' not in p
assert p['ParrotKeychainService'] == p['CFBundleIdentifier']
assert p['CFBundleIdentifier'] != 'com.uygar.parrot'
Path('build-evidence/test-bundle-id.txt').write_text(test_id + '\n')
Path('build-evidence/architecture.txt').write_text(architecture + '\n')
Path('build-evidence/test-info.plist').write_bytes(info.read_bytes())
PY
codesign --force --options runtime --timestamp=none \
  --entitlements build-evidence/test-entitlements.plist --sign - dist/Parrot.app
codesign --verify --deep --strict dist/Parrot.app
xcrun vtool -show-build dist/Parrot.app/Contents/MacOS/Parrot | tee build-evidence/macho-build.txt
git rev-parse HEAD > build-evidence/source-commit.txt
shasum -a 256 dist/Parrot.app/Contents/MacOS/Parrot > build-evidence/binary.sha256
ditto -c -k --keepParent dist/Parrot.app Parrot-local-candidate.zip
shasum -a 256 Parrot-local-candidate.zip > build-evidence/archive.sha256
python3 - <<'PY'
from pathlib import Path
import subprocess
with Path('build-evidence/query-startup.log').open('w') as output:
    result = subprocess.run(['dist/Parrot.app/Contents/MacOS/Parrot', '--query-startup-test'],
                            stdout=output, stderr=subprocess.STDOUT, timeout=30)
    result.check_returncode()
PY
tail -1 build-evidence/query-startup.log
python3 - <<'PY'
from pathlib import Path
import subprocess
with Path('build-evidence/qa-setup-model-owners.log').open('w') as output:
    results = []
    for owner in ['speech', 'speakers', 'local', 'embedding']:
        output.write('OWNER ' + owner + '\n'); output.flush()
        try:
            result = subprocess.run(['dist/Parrot.app/Contents/MacOS/Parrot', '--qa-setup',
                                     '--qa-setup-self-check', owner],
                                    stdout=output, stderr=subprocess.STDOUT, timeout=15)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
        results.append(code)
        output.write('EXIT ' + str(code) + '\n'); output.flush()
    if any(code != 0 for code in results):
        raise SystemExit('QA setup model-owner checks failed: ' + repr(results))
PY
tail -1 build-evidence/qa-setup-model-owners.log

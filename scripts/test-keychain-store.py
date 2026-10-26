#!/usr/bin/env python3
"""Run the actual credential helper against an in-memory Security API boundary.

No system keychain APIs, user credentials, app data or audio are accessed.
The helper is extracted unchanged from production so this runs with the CLT
even when Apple's Xcode-only SwiftData macro plugin is unavailable.
"""
from pathlib import Path
import subprocess
import tempfile
import plistlib
import shutil

root = Path(__file__).resolve().parents[1]
source = (root / 'Parrot/Services/AnalysisProvider.swift').read_text()
helper = source[source.index('enum APIKeyStore {'):]
with tempfile.TemporaryDirectory(prefix='parrot-keychain-regression-') as temp:
    temp = Path(temp)
    (temp / 'APIKeyStoreUnderTest.swift').write_text(
        'import Foundation\nimport Security\nimport os\n' + helper)
    (temp / 'main.swift').write_text((root / 'scripts/credential-regression.swift').read_text())
    binary = temp / 'credential-tests'
    subprocess.run(['swiftc', '-swift-version', '5', str(temp / 'APIKeyStoreUnderTest.swift'),
                    str(temp / 'main.swift'), '-o', str(binary)], check=True)
    undefined = subprocess.check_output(['nm', '-u', str(binary)], text=True)
    for name in ['SecItemCopyMatching', 'SecItemAdd', 'SecItemUpdate', 'SecItemDelete']:
        if '_' + name in undefined:
            raise SystemExit('Refusing to run a regression binary linked to real ' + name)
    print('Verified: no real SecItem function calls are linked', flush=True)
    status = 0
    for session_only in [False, True]:
        app = temp / ('session.app' if session_only else 'normal.app')
        executable = app / 'Contents/MacOS/credential-tests'
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'credential-tests', 'CFBundlePackageType': 'APPL',
            'CFBundleIdentifier': 'test.parrot.credentials',
            'ParrotSessionOnlyCredentials': session_only,
        }))
        arguments = ['--session-only-tests'] if session_only else []
        status |= subprocess.run([str(executable)] + arguments).returncode
    raise SystemExit(status)

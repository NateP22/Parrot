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
import os
import platform

root = Path(__file__).resolve().parents[1]
source = (root / 'Parrot/Services/AnalysisProvider.swift').read_text()
helper = source[source.index('enum APIKeyStore {'):]
with tempfile.TemporaryDirectory(prefix='parrot-keychain-regression-') as temp:
    temp = Path(temp)
    (temp / 'APIKeyStoreUnderTest.swift').write_text(
        'import Foundation\nimport Security\nimport LocalAuthentication\nimport os\n' + helper)
    checks = (root / 'scripts/credential-regression.swift').read_text()
    boundary = checks.index('if CommandLine.arguments.contains("--no-ui-tests")')
    # Exercise synchronous store checks on a worker, as real background loads
    # now require. The main dispatcher remains available for async branches.
    checks = checks[:boundary] + '\nfunc runRegression() {\n' + checks[boundary:].replace('dispatchMain()', 'return') + '\n}\nDispatchQueue.global().async { runRegression() }\ndispatchMain()\n'
    (temp / 'main.swift').write_text(checks)
    binary = temp / 'credential-tests'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk, str(temp / 'APIKeyStoreUnderTest.swift'),
                    str(temp / 'main.swift'), '-o', str(binary)], check=True)
    undefined = subprocess.check_output(['nm', '-u', str(binary)], text=True)
    for name in ['SecItemCopyMatching', 'SecItemAdd', 'SecItemUpdate', 'SecItemDelete', 'SecKeychainSetUserInteractionAllowed', 'SecKeychainGetUserInteractionAllowed']:
        if '_' + name in undefined:
            raise SystemExit('Refusing to run a regression binary linked to real ' + name)
    print('Verified: no real SecItem function calls are linked', flush=True)
    status = 0
    qa_id = 'com.uygar.parrot.sat54.qa'
    configurations = [
        ('production', 'com.uygar.parrot', None, False, []),
        ('qa-persistent', qa_id, qa_id, False, []),
        ('qa-missing-service', qa_id, None, False, ['--invalid-service-tests']),
        ('qa-blank-service', qa_id, '', False, ['--invalid-service-tests']),
        ('qa-original-service', qa_id, 'com.uygar.parrot', False, ['--invalid-service-tests']),
        ('parent-id-original-service', 'com.uygar', 'com.uygar.parrot', False, ['--invalid-service-tests']),
        ('qa-other-service', qa_id, 'test.other.app', False, ['--invalid-service-tests']),
        ('qa-session', qa_id, qa_id + '.session-only', True, ['--session-only-tests']),
    ]
    for label, bundle_id, service, session_only, arguments in configurations:
        app = temp / (label + '.app')
        executable = app / 'Contents/MacOS/credential-tests'
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        info = {
            'CFBundleExecutable': 'credential-tests', 'CFBundlePackageType': 'APPL',
            'CFBundleIdentifier': bundle_id,
            'ParrotSessionOnlyCredentials': session_only,
        }
        if service is not None:
            info['ParrotKeychainService'] = service
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        print('Configuration: ' + label, flush=True)
        status |= subprocess.run([str(executable)] + arguments).returncode
        if label == 'qa-persistent':
            status |= subprocess.run([str(executable), '--no-ui-tests']).returncode
            status |= subprocess.run([str(executable), '--settings-lookup-tests'], timeout=15).returncode
            env = dict(os.environ, PARROT_TEST_FAKE_STORE=str(temp / 'synthetic-security-boundary.json'))
            for phase in ['write', 'read']:
                status |= subprocess.run([str(executable), '--persistence-phase', phase], env=env).returncode
    raise SystemExit(status)

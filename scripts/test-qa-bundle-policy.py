#!/usr/bin/env python3
"""Execute the real packaging configuration on disposable fake app bundles.

No build, codesigning, keychain, audio, real app or user data is accessed.
"""
from pathlib import Path
import os
import plistlib
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class QABundlePolicy(unittest.TestCase):
    def configure(self, revision):
        source = (ROOT / 'scripts/build-local-candidate.sh').read_text()
        block = re.search(r"python3 - <<'PY'\n(.*?)\nPY", source, re.S).group(1)
        with tempfile.TemporaryDirectory(prefix='parrot-qa-policy-') as name:
            base = Path(name)
            (base / 'dist/Parrot.app/Contents').mkdir(parents=True)
            (base / 'Parrot').mkdir()
            (base / 'build-evidence').mkdir()
            (base / 'bin').mkdir()
            info = base / 'dist/Parrot.app/Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.uygar.parrot', 'SUFeedURL': 'https://example.invalid/feed'}))
            (base / 'Parrot/Parrot.entitlements').write_bytes((ROOT / 'Parrot/Parrot.entitlements').read_bytes())
            git = base / 'bin/git'
            git.write_text('#!/bin/sh\nprintf "%s\\n" "' + revision + '"\n')
            git.chmod(0o700)
            subprocess.run(['/usr/bin/python3', '-c', block], cwd=base,
                           env=dict(os.environ, PATH=str(base / 'bin') + ':' + os.environ['PATH']), check=True)
            return plistlib.loads(info.read_bytes())

    def test_supported_qa_restarts_with_persistent_own_service(self):
        info = self.configure('a' * 40)
        self.assertFalse(info.get('ParrotSessionOnlyCredentials', False), 'Daily-use QA must persist its own credentials')
        self.assertEqual(info['CFBundleIdentifier'], 'com.uygar.parrot.sat54.qa')
        self.assertEqual(info['ParrotKeychainService'], info['CFBundleIdentifier'])
        self.assertEqual(info['CFBundleDisplayName'], 'Parrot SAT54 QA')
        self.assertNotIn('SUFeedURL', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])

    def test_update_keeps_qa_container_and_service_without_claiming_grant_continuity(self):
        first, second = self.configure('a' * 40), self.configure('b' * 40)
        self.assertEqual(first['CFBundleIdentifier'], second['CFBundleIdentifier'])
        self.assertEqual(first['ParrotKeychainService'], second['ParrotKeychainService'])
        self.assertEqual(first.get('ParrotSourceCommit'), 'a' * 40)
        self.assertEqual(second.get('ParrotSourceCommit'), 'b' * 40)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Synthetic packaging-policy tests; no app, compiler, keys, models or audio."""
from pathlib import Path
import copy
import importlib.util
import plistlib
import unittest
from unittest import mock
import contextlib
import hashlib
import os
import tempfile
import zipfile
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'a' * 40
QA = 'com.uygar.parrot.sat54.qa'

class CrossCandidatePolicy(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'scripts/prepare-arm-cross-candidate.py'
        self.assertTrue(path.is_file(), 'Cross policy missing: current builder only labels its native host')
        spec = importlib.util.spec_from_file_location('arm_cross_policy', path)
        self.policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.policy)
        self.host = dict(CFBundleIdentifier=QA, CFBundleName='Parrot SAT54 QA',
            CFBundleDisplayName='Parrot SAT54 QA', CFBundleExecutable='Parrot',
            LSMinimumSystemVersion='14.0', ParrotSourceCommit=SOURCE,
            ParrotBuildArchitecture='x86_64', ParrotKeychainService=QA,
            ParrotSessionOnlyCredentials=False, ParrotNativeAnswerTrace=True,
            ParrotQASetupByDefault=True, ParrotQACredentialProbeVersion=1,
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
            CFBundleURLTypes=[dict(CFBundleURLSchemes=['openparrot'])])

    def target(self, host=None, source=SOURCE, host_arch='x86_64', archs=None, minos='14.0'):
        return self.policy.prepare_info(self.host if host is None else host, source, host_arch,
                                        ['arm64'] if archs is None else archs, minos)

    def test_arm_target_is_not_labeled_as_its_intel_host(self):
        info = self.target()
        self.assertEqual(info['ParrotBuildArchitecture'], 'arm64')
        self.assertEqual(info['ParrotBuildHostArchitecture'], 'x86_64')
        self.assertEqual(info['ParrotARMExecutionStatus'], 'pending')

    def test_qa_policy_and_template_are_preserved(self):
        before = copy.deepcopy(self.host)
        info = self.target()
        self.assertEqual(self.host, before)
        self.assertEqual(info['ParrotKeychainService'], QA)
        for field in ['ParrotSessionOnlyCredentials', 'SUAutomaticallyUpdate']:
            self.assertIs(info[field], False)
        self.assertIs(info['ParrotQASetupByDefault'], True)
        info['CFBundleURLTypes'][0]['CFBundleURLSchemes'].append('test-only')
        self.assertEqual(self.host, before)

    def test_original_identity_or_service_is_rejected(self):
        for field in ['CFBundleIdentifier', 'ParrotKeychainService']:
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'qa_identity'):
                self.target(host=dict(self.host, **{field: 'com.uygar.parrot'}))

    def test_security_policy_flags_are_typed_and_exact(self):
        invalid = dict(ParrotSessionOnlyCredentials=True, ParrotNativeAnswerTrace=1,
            ParrotQASetupByDefault=1, ParrotQACredentialProbeVersion=True,
            SUEnableAutomaticChecks=0, SUAutomaticallyUpdate=True)
        for field, value in invalid.items():
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'qa_policy'):
                self.target(host=dict(self.host, **{field: value}))

    def test_update_feed_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'qa_policy'):
            self.target(host=dict(self.host, SUFeedURL='https://example.invalid/feed'))

    def test_different_or_invalid_source_is_rejected(self):
        for source in ['b' * 40, 'A' * 40, 'not-a-commit']:
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'source'):
                self.target(source=source)

    def test_wrong_host_or_host_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'host_architecture'):
            self.target(host_arch='arm64')
        with self.assertRaisesRegex(ValueError, 'host_architecture'):
            self.target(host=dict(self.host, ParrotBuildArchitecture='arm64'))

    def test_target_must_be_arm_only(self):
        for archs in [[], ['x86_64'], ['arm64', 'x86_64'], ['arm64', 'arm64']]:
            with self.subTest(archs=archs), self.assertRaisesRegex(ValueError, 'target_architecture'):
                self.target(archs=archs)

    def test_target_minimum_os_matches_verified_qa_policy(self):
        for minos in ['13.0', '15.0', '26.x', '']:
            with self.subTest(minos=minos), self.assertRaisesRegex(ValueError, 'minimum_os'):
                self.target(minos=minos)

    def test_build_version_parser_accepts_actual_macos_metadata(self):
        for sdk in ['26.2', '26.5']:
            result = self.policy.parse_build_version('platform MACOS\nminos 14.0\nsdk ' + sdk + '\n')
            self.assertEqual(result, dict(platform='MACOS', minos='14.0', sdk=sdk))

    def test_build_version_parser_rejects_missing_foreign_or_old_sdk(self):
        for text in ['platform IOS\nminos 14.0\nsdk 26.2\n', 'platform MACOS\nminos 14.0\n',
                     'platform MACOS\nminos 14.0\nsdk 15.5\n',
                     'platform MACOS\nminos 14.0\nsdk 26.x\n']:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'build_version'):
                self.policy.parse_build_version(text)

    def test_entitlements_match_source_plus_existing_library_policy(self):
        base = plistlib.loads((ROOT / 'Parrot/Parrot.entitlements').read_bytes())
        expected = dict(base, **{'com.apple.security.cs.disable-library-validation': True})
        before = copy.deepcopy(expected)
        self.assertEqual(self.policy.validate_entitlements(expected, base), expected)
        self.assertEqual(expected, before)

    def test_missing_or_expanded_entitlements_are_rejected(self):
        base = plistlib.loads((ROOT / 'Parrot/Parrot.entitlements').read_bytes())
        expected = dict(base, **{'com.apple.security.cs.disable-library-validation': True})
        for host in [base, dict(expected, **{'com.apple.security.get-task-allow': True})]:
            with self.subTest(host=host), self.assertRaisesRegex(ValueError, 'entitlements'):
                self.policy.validate_entitlements(host, base)

    def test_manifest_never_promotes_unexecuted_arm_or_native_work(self):
        result = self.policy.pending_execution()
        self.assertEqual(result['status'], 'BUILD_ONLY_PENDING_ARM_EXECUTION')
        self.assertIs(result['native_acceptance'], False)
        self.assertEqual(set(result['arm_checks']), {'full_profile', 'query_startup', 'setup_model_owners',
            'synthetic_credentials', 'window_lifecycle', 'real_provider', 'system_audio', 'final_qualification'})
        self.assertTrue(all(value == 'pending' for value in result['arm_checks'].values()))

class CrossCandidateWorkspace(unittest.TestCase):
    def setUp(self):
        CrossCandidatePolicy.setUp(self)
        self.bad_signature = False
        self.bad_nested = False
        self.bad_embedded_entitlements = False
        self.bad_runtime = False

    def tool(self, argv, cwd=None):
        if argv == ['/usr/bin/uname', '-m']: return 'x86_64'
        if argv[:3] == ['/usr/bin/git', 'rev-parse', 'HEAD']: return SOURCE
        if argv[:2] == ['/usr/bin/lipo', '-archs']:
            if self.bad_nested and str(argv[-1]).endswith('/Versions/B/Sparkle'): return 'x86_64'
            return 'arm64'
        if argv[:3] == ['/usr/bin/xcrun', 'vtool', '-show-build']:
            return 'platform MACOS\nminos 14.0\nsdk 26.5\n'
        if argv[:2] == ['/usr/bin/codesign', '--verify']:
            if self.bad_signature: raise ValueError('signature_failed')
            return ''
        if argv[:3] == ['/usr/bin/codesign', '--display', '--entitlements']:
            base = plistlib.loads((ROOT / 'Parrot/Parrot.entitlements').read_bytes())
            actual = dict(base, **{'com.apple.security.cs.disable-library-validation': True})
            if self.bad_embedded_entitlements: actual['com.apple.security.get-task-allow'] = True
            return plistlib.dumps(actual).decode()
        if argv[:3] == ['/usr/bin/codesign', '--display', '--verbose=4']:
            return 'CodeDirectory flags=0x2(adhoc)' if self.bad_runtime else 'CodeDirectory flags=0x10002(adhoc,runtime)'
        self.fail('Unexpected external tool: ' + repr(argv))

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(prefix='parrot-cross-policy-') as name:
            root = Path(name)
            host = root / 'build-evidence/host-x86_64'
            host.mkdir(parents=True)
            (root / 'Parrot').mkdir()
            base = plistlib.loads((ROOT / 'Parrot/Parrot.entitlements').read_bytes())
            (root / 'Parrot/Parrot.entitlements').write_bytes(plistlib.dumps(base))
            (host / 'test-info.plist').write_bytes(plistlib.dumps(self.host))
            ents = dict(base, **{'com.apple.security.cs.disable-library-validation': True})
            (host / 'test-entitlements.plist').write_bytes(plistlib.dumps(ents))
            (host / 'source-commit.txt').write_text(SOURCE + '\n')
            (host / 'profile-test.log').write_text('PASS synthetic fixture\nALL PASS\n')
            app = root / 'dist/Parrot.app'
            paths = ['Contents/MacOS/Parrot',
                'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
                'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
                'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
                'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer']
            for relative in paths:
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'\xcf\xfa\xed\xfe' + b'synthetic-non-executable')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier':'com.uygar.parrot', 'CFBundleExecutable':'Parrot',
                'LSMinimumSystemVersion':'14.0'}))
            with mock.patch.dict(os.environ, {'GITHUB_ACTIONS':'true'}), \
                 mock.patch.object(self.policy, 'run', side_effect=self.tool, create=True):
                yield root

    def prepare(self, root):
        self.assertTrue(callable(getattr(self.policy, 'prepare_workspace', None)),
                        'CI workspace preparation is missing')
        return self.policy.prepare_workspace(root)

    def finalize(self, root):
        self.assertTrue(callable(getattr(self.policy, 'finalize_workspace', None)),
                        'ARM archive finalization is missing')
        return self.policy.finalize_workspace(root)

    def archive(self, root, tamper=False):
        app = root / 'dist/Parrot.app'
        with zipfile.ZipFile(root / 'Parrot-arm64-build-only.zip', 'x') as archive:
            for path in sorted(app.rglob('*')):
                if path.is_file():
                    data = path.read_bytes()
                    if tamper and path == app / 'Contents/MacOS/Parrot': data = b'changed-binary'
                    archive.writestr('Parrot.app/' + path.relative_to(app).as_posix(), data)

    def test_prepare_clones_host_policy_without_changing_host_or_binary(self):
        with self.fixture() as root:
            host_info = root / 'build-evidence/host-x86_64/test-info.plist'
            binary = root / 'dist/Parrot.app/Contents/MacOS/Parrot'
            before = (host_info.read_bytes(), binary.read_bytes())
            result = self.prepare(root)
            info = plistlib.loads((root / 'dist/Parrot.app/Contents/Info.plist').read_bytes())
            self.assertEqual(info, self.policy.prepare_info(self.host, SOURCE, 'x86_64', ['arm64'], '14.0'))
            self.assertEqual(before, (host_info.read_bytes(), binary.read_bytes()))
            self.assertFalse(result['native_acceptance'])
            self.assertTrue((root / 'build-evidence/arm64-target/PREPARED.json').is_file())

    def test_wrong_source_fails_before_policy_writes(self):
        with self.fixture() as root:
            (root / 'build-evidence/host-x86_64/source-commit.txt').write_text('b' * 40)
            info = root / 'dist/Parrot.app/Contents/Info.plist'
            before = info.read_bytes()
            with self.assertRaisesRegex(ValueError, 'source'): self.prepare(root)
            self.assertEqual(info.read_bytes(), before)
            self.assertFalse((root / 'build-evidence/arm64-target').exists())

    def test_failed_host_profile_fails_before_policy_writes(self):
        with self.fixture() as root:
            (root / 'build-evidence/host-x86_64/profile-test.log').write_text('FAILURES: 1\n')
            with self.assertRaisesRegex(ValueError, 'host_profile'): self.prepare(root)
            self.assertFalse((root / 'build-evidence/arm64-target').exists())

    def test_ci_only_guard_precedes_policy_writes(self):
        with self.fixture() as root, mock.patch.dict(os.environ, {'GITHUB_ACTIONS':'false'}):
            with self.assertRaisesRegex(ValueError, 'ci_only'): self.prepare(root)
            self.assertFalse((root / 'build-evidence/arm64-target').exists())

    def test_final_archive_binds_real_bytes_and_keeps_all_arm_work_pending(self):
        with self.fixture() as root:
            self.prepare(root)
            self.archive(root)
            result = self.finalize(root)
            self.assertFalse(result['native_acceptance'])
            self.assertEqual(result['status'], 'BUILD_ONLY_PENDING_ARM_EXECUTION')
            self.assertTrue(all(x == 'pending' for x in result['arm_checks'].values()))
            binary = root / 'dist/Parrot.app/Contents/MacOS/Parrot'
            self.assertEqual(result['binary_sha256'], hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertEqual(result['target_architecture'], 'arm64')
            self.assertEqual(result['host_architecture'], 'x86_64')
            self.assertEqual(result['source_commit'], SOURCE)
            self.assertEqual(len(result['macho_members']), 5)
            self.assertTrue((root / 'build-evidence/arm64-target/manifest.json').is_file())

    def test_signature_failure_cannot_produce_a_final_manifest(self):
        with self.fixture() as root:
            self.prepare(root); self.archive(root); self.bad_signature = True
            with self.assertRaisesRegex(ValueError, 'signature'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_missing_nested_arm_slice_cannot_produce_a_final_manifest(self):
        with self.fixture() as root:
            self.prepare(root); self.archive(root); self.bad_nested = True
            with self.assertRaisesRegex(ValueError, 'nested_arm'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_changed_archived_binary_is_rejected(self):
        with self.fixture() as root:
            self.prepare(root); self.archive(root, tamper=True)
            with self.assertRaisesRegex(ValueError, 'archive'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_changed_prepared_policy_is_rejected(self):
        with self.fixture() as root:
            self.prepare(root)
            info_path = root / 'dist/Parrot.app/Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes()); info['ParrotQASetupByDefault'] = False
            info_path.write_bytes(plistlib.dumps(info)); self.archive(root)
            with self.assertRaisesRegex(ValueError, 'prepared_policy'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_embedded_entitlements_mismatch_is_rejected(self):
        with self.fixture() as root:
            self.prepare(root); self.archive(root); self.bad_embedded_entitlements = True
            with self.assertRaisesRegex(ValueError, 'entitlements'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_missing_actual_hardened_runtime_is_rejected(self):
        with self.fixture() as root:
            self.prepare(root); self.archive(root); self.bad_runtime = True
            with self.assertRaisesRegex(ValueError, 'hardened_runtime'): self.finalize(root)
            self.assertFalse((root / 'build-evidence/arm64-target/manifest.json').exists())

    def test_wrapper_refuses_outside_ci_before_creating_artifacts(self):
        script = ROOT / 'scripts/build-arm-cross-candidate.sh'
        self.assertTrue(script.is_file(), 'CI-only cross-build wrapper is missing')
        with tempfile.TemporaryDirectory(prefix='parrot-cross-wrapper-') as name:
            root = Path(name); (root / 'scripts').mkdir()
            copy_path = root / 'scripts/build-arm-cross-candidate.sh'
            copy_path.write_bytes(script.read_bytes())
            env = dict(os.environ, GITHUB_ACTIONS='false')
            result = subprocess.run(['/bin/bash', str(copy_path)], env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('cross-build is CI-only', result.stderr)
            self.assertFalse((root / 'dist').exists())
            self.assertFalse((root / 'build-evidence').exists())

if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""CI ARM packaging policy. BUILD_ONLY is never local ARM/native acceptance."""
from pathlib import Path
import copy
import re

QA_ID = 'com.uygar.parrot.sat54.qa'

def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
        raise ValueError('invalid_version')
    parts = tuple(int(x) for x in value.split('.'))
    return parts + (0,) * (3 - len(parts))

def prepare_info(host_info, source, host_arch, target_archs, target_minos):
    if not isinstance(host_info, dict):
        raise ValueError('qa_identity')
    if any(host_info.get(key) != QA_ID for key in ('CFBundleIdentifier', 'ParrotKeychainService')):
        raise ValueError('qa_identity')
    expected = dict(ParrotSessionOnlyCredentials=False, ParrotNativeAnswerTrace=True,
        ParrotQASetupByDefault=True, ParrotQACredentialProbeVersion=1,
        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
    if any(type(host_info.get(key)) is not type(value) or host_info[key] != value
           for key, value in expected.items()) or 'SUFeedURL' in host_info:
        raise ValueError('qa_policy')
    if (host_info.get('CFBundleExecutable') != 'Parrot' or
        host_info.get('CFBundleName') != 'Parrot SAT54 QA' or
        host_info.get('CFBundleDisplayName') != 'Parrot SAT54 QA'):
        raise ValueError('qa_policy')
    if (not isinstance(source, str) or not re.fullmatch('[a-f0-9]{40}', source) or
        host_info.get('ParrotSourceCommit') != source):
        raise ValueError('source_mismatch')
    if host_arch != 'x86_64' or host_info.get('ParrotBuildArchitecture') != 'x86_64':
        raise ValueError('host_architecture')
    if target_archs != ['arm64']:
        raise ValueError('target_architecture')
    try:
        if version(host_info.get('LSMinimumSystemVersion')) != (14, 0, 0) or version(target_minos) != (14, 0, 0):
            raise ValueError('minimum_os')
    except ValueError as error:
        raise ValueError('minimum_os') from error
    result = copy.deepcopy(host_info)
    result.update(ParrotBuildArchitecture='arm64', ParrotBuildHostArchitecture=host_arch,
                  ParrotARMExecutionStatus='pending')
    return result

def parse_build_version(text):
    result = {}
    for line in text.splitlines():
        match = re.fullmatch(r'\s*(platform|minos|sdk)\s+(\S+)\s*', line)
        if match:
            key, value = match.groups()
            if key in result:
                raise ValueError('build_version_duplicate')
            result[key] = value
    try:
        if set(result) != {'platform', 'minos', 'sdk'} or result['platform'] != 'MACOS':
            raise ValueError('build_version_fields')
        version(result['minos'])
        if version(result['sdk'])[0] < 26:
            raise ValueError('build_version_sdk')
    except ValueError as error:
        raise ValueError('build_version') from error
    return result

def validate_entitlements(host, base):
    import plistlib
    if not isinstance(host, dict) or not isinstance(base, dict):
        raise ValueError('entitlements')
    expected = dict(base, **{'com.apple.security.cs.disable-library-validation': True})
    if plistlib.dumps(host) != plistlib.dumps(expected):
        raise ValueError('entitlements')
    return copy.deepcopy(host)

def pending_execution():
    return dict(status='BUILD_ONLY_PENDING_ARM_EXECUTION', native_acceptance=False,
        arm_checks={key:'pending' for key in ('full_profile', 'query_startup', 'setup_model_owners',
            'synthetic_credentials', 'window_lifecycle', 'real_provider', 'system_audio',
            'final_qualification')})
# The CLI operates only inside its own CI checkout. Unit tests pass disposable roots.
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import zipfile

CODE_MEMBERS = (
    'Contents/MacOS/Parrot',
    'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
    'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
    'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
    'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
)
MACHO_MAGICS = {bytes.fromhex(x) for x in
    ('cffaedfe','feedfacf','cefaedfe','feedface','cafebabe','bebafeca','cafebabf','bfbafeca')}

def run(argv, cwd=None):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, text=True,
                            capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(Path(str(argv[0])).name + '_failed: ' + result.stderr[:2000])
    if str(argv[0]) == '/usr/bin/codesign' and '--display' in argv and '--verbose=4' in argv:
        return (result.stdout + result.stderr).strip()
    return result.stdout.strip()

def digest_stream(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda:stream.read(1024 * 1024), b''):
        value.update(chunk)
    return value.hexdigest()

def digest(path):
    with Path(path).open('rb') as stream: return digest_stream(stream)

def read_regular(path, limit=128 * 1024):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError('invalid_input_file:' + path.name)
    value = path.read_bytes()
    if len(value) > limit: raise ValueError('input_limit:' + path.name)
    return value

def inputs(root):
    root = Path(root).resolve()
    if os.environ.get('GITHUB_ACTIONS') != 'true': raise ValueError('ci_only')
    host_arch = run(['/usr/bin/uname', '-m'])
    if host_arch != 'x86_64': raise ValueError('host_architecture')
    source = run(['/usr/bin/git', 'rev-parse', 'HEAD'], cwd=root)
    host = root / 'build-evidence/host-x86_64'
    if read_regular(host / 'source-commit.txt', 64).decode().strip() != source:
        raise ValueError('source_mismatch')
    profile = read_regular(host / 'profile-test.log', 4 * 1024 * 1024).decode().splitlines()
    if not profile or profile[-1].strip() != 'ALL PASS': raise ValueError('host_profile_failed')
    host_info = plistlib.loads(read_regular(host / 'test-info.plist'))
    app = root / 'dist/Parrot.app'
    binary = app / CODE_MEMBERS[0]
    archs = run(['/usr/bin/lipo', '-archs', binary]).split()
    build_text = run(['/usr/bin/xcrun', 'vtool', '-show-build', binary])
    build = parse_build_version(build_text)
    info = prepare_info(host_info, source, host_arch, archs, build['minos'])
    current = plistlib.loads(read_regular(app / 'Contents/Info.plist'))
    if current.get('CFBundleExecutable') != 'Parrot' or version(current.get('LSMinimumSystemVersion')) != (14, 0, 0):
        raise ValueError('target_base_policy')
    base = plistlib.loads(read_regular(root / 'Parrot/Parrot.entitlements'))
    entitlements = validate_entitlements(
        plistlib.loads(read_regular(host / 'test-entitlements.plist')), base)
    return root, app, host, source, info, entitlements, build, build_text

def prepare_workspace(root):
    root, app, host, source, info, ents, build, build_text = inputs(root)
    output = root / 'build-evidence/arm64-target'
    output.mkdir(exist_ok=False)
    encoded_info = plistlib.dumps(info)
    encoded_ents = plistlib.dumps(ents)
    (app / 'Contents/Info.plist').write_bytes(encoded_info)
    (output / 'test-info.plist').write_bytes(encoded_info)
    (output / 'test-entitlements.plist').write_bytes(encoded_ents)
    (output / 'macho-build.txt').write_text(build_text + '\n')
    result = dict(pending_execution(), source_commit=source, host_architecture='x86_64',
        target_architecture='arm64', build_version=build,
        info_sha256=hashlib.sha256(encoded_info).hexdigest(),
        entitlements_sha256=hashlib.sha256(encoded_ents).hexdigest(),
        host_info_sha256=digest(host / 'test-info.plist'),
        host_profile_log_sha256=digest(host / 'profile-test.log'))
    with (output / 'PREPARED.json').open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True); stream.write('\n')
    return result

def finalize_workspace(root):
    root, app, host, source, info, ents, build, _ = inputs(root)
    output = root / 'build-evidence/arm64-target'
    prepared = json.loads(read_regular(output / 'PREPARED.json'))
    current_info = read_regular(app / 'Contents/Info.plist')
    current_ents = read_regular(output / 'test-entitlements.plist')
    if (plistlib.loads(current_info) != info or plistlib.loads(current_ents) != ents or
        digest(app / 'Contents/Info.plist') != prepared.get('info_sha256') or
        digest(output / 'test-entitlements.plist') != prepared.get('entitlements_sha256') or
        prepared.get('source_commit') != source or
        prepared.get('host_info_sha256') != digest(host / 'test-info.plist') or
        prepared.get('host_profile_log_sha256') != digest(host / 'profile-test.log')):
        raise ValueError('prepared_policy_changed')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    embedded = plistlib.loads(run(['/usr/bin/codesign', '--display', '--entitlements', ':-', app]).encode())
    if plistlib.dumps(embedded) != plistlib.dumps(ents): raise ValueError('embedded_entitlements_mismatch')
    signature = run(['/usr/bin/codesign', '--display', '--verbose=4', app])
    flags = re.search(r'\bflags=0x([a-fA-F0-9]+)\b', signature)
    if not flags or int(flags.group(1), 16) & 0x10000 == 0:
        raise ValueError('hardened_runtime_missing')
    members = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError('bundle_symlink_escape')
            continue
        if not path.is_file(): continue
        with path.open('rb') as stream: magic = stream.read(4)
        if magic not in MACHO_MAGICS: continue
        archs = run(['/usr/bin/lipo', '-archs', path]).split()
        if 'arm64' not in archs: raise ValueError('nested_arm_slice_missing')
        members.append(dict(path=path.relative_to(app).as_posix(), architectures=archs, sha256=digest(path)))
    if not set(CODE_MEMBERS).issubset({x['path'] for x in members}):
        raise ValueError('nested_arm_required_code_missing')
    archive_path = root / 'Parrot-arm64-build-only.zip'
    binary_sha = digest(app / CODE_MEMBERS[0])
    info_sha = digest(app / 'Contents/Info.plist')
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(n.startswith('/') or '..' in n.split('/') or '\\' in n for n in names):
            raise ValueError('archive_paths')
        if archive.testzip() is not None: raise ValueError('archive_crc')
        for relative, expected in [(CODE_MEMBERS[0], binary_sha), ('Contents/Info.plist', info_sha)]:
            with archive.open('Parrot.app/' + relative) as stream:
                if digest_stream(stream) != expected: raise ValueError('archive_bytes_mismatch')
    result = dict(pending_execution(), source_commit=source, host_architecture='x86_64',
        target_architecture='arm64', build_version=build, binary_sha256=binary_sha,
        info_sha256=info_sha, archive_sha256=digest(archive_path),
        entitlements_sha256=digest(output / 'test-entitlements.plist'),
        host_info_sha256=digest(host / 'test-info.plist'),
        host_profile_log_sha256=digest(host / 'profile-test.log'),
        bundle_signature='deep_strict_verified', hardened_runtime=True,
        embedded_entitlements_sha256=hashlib.sha256(plistlib.dumps(embedded)).hexdigest(),
        macho_members=members)
    with (output / 'manifest.json').open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True); stream.write('\n')
    return result

if __name__ == '__main__':
    try:
        if sys.argv[1:] not in ([], ['--finalize']): raise ValueError('invalid_arguments')
        root = Path(__file__).resolve().parents[1]
        result = finalize_workspace(root) if sys.argv[1:] else prepare_workspace(root)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('ARM cross-build refused: ' + str(error), file=sys.stderr)
        raise SystemExit(1)

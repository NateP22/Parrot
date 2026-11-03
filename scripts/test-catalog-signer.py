#!/usr/bin/env python3
"""Actual signer CLI with synthetic local key/payloads; no production key or app."""
from pathlib import Path
import base64
import copy
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = failures = 0


def check(name, passed):
    global checks, failures
    checks += 1
    if not passed:
        failures += 1
        print('FAIL ' + name)


with tempfile.TemporaryDirectory(prefix='parrot-catalog-signer-') as directory:
    temp = Path(directory)
    signer = temp/'catalog-signer'
    subprocess.run(['swiftc', '-parse-as-library', str(root/'scripts/catalog-sign.swift'),
                    '-module-cache-path', str(temp/'module-cache'), '-o', str(signer)],
                   check=True, timeout=120)
    # Public, deterministic fixture material, never a real credential/trust root.
    key = temp/'fictional-test-key'
    key.write_bytes(bytes(range(1, 33)))
    key.chmod(0o600)
    verify_source = temp/'Verify.swift'
    verify_source.write_text(r'''
import Foundation
import CryptoKit
let a = CommandLine.arguments
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[1]))) as! [String: String]
let payload = Data(base64Encoded: object["payload"]!)!
let signature = Data(base64Encoded: object["signature"]!)!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map { UInt8($0) }))
guard payload == (try Data(contentsOf: URL(fileURLWithPath: a[2]))),
      key.publicKey.isValidSignature(signature, for: payload) else { exit(1) }
print("SYNTHETIC_SIGNATURE_VERIFIED")
''')
    verifier = temp/'verify'
    subprocess.run(['swiftc', str(verify_source), '-module-cache-path', str(temp/'module-cache'),
                    '-o', str(verifier)], check=True, timeout=120)

    def invoke(label, value, expected_format=None, approved=None, missing_key=False):
        payload = temp/(label+'.json')
        output = temp/(label+'-signed.json')
        raw = (json.dumps(value, sort_keys=True)+'\n').encode()
        payload.write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        result = subprocess.run([str(signer), 'sign', str(temp/'absent' if missing_key else key),
            str(payload), approved or digest, str(output)], capture_output=True, timeout=15)
        if expected_format:
            check(label+' exits successfully', result.returncode == 0)
            if not output.exists():
                check(label+' writes envelope', False)
                return
            envelope = json.loads(output.read_text())
            check(label+' envelope format exact', envelope['format'] == expected_format)
            check(label+' payload bytes exact', base64.b64decode(envelope['payload']) == raw)
            verified = subprocess.run([str(verifier), str(output), str(payload)], capture_output=True, timeout=10)
            check(label+' actual CryptoKit signature verifies', verified.returncode == 0)
            check(label+' output contains only approved digest', result.stdout.decode().strip() == 'Signed approved payload '+digest)
        else:
            check(label+' rejected without output', result.returncode != 0 and not output.exists())
            check(label+' rejected by signer guard before absent key read', b'CatalogSigner' in result.stderr)

    legacy = dict(format='parrot-reviewed-answers-v2')
    invoke('legacy-v2', legacy, 'parrot-reviewed-answers-signed-v2')
    fact = dict(format='parrot-reviewed-facts-v1', mode='reviewedFacts', answers=[], facts=[dict(
        review=dict(verdict='PASS_SOURCE_FACT', reviewer='fictional reviewer', reviewedAt='2026-01-01', digest='a'*64))])
    invoke('reviewed-fact', fact, 'parrot-reviewed-facts-signed-v1')
    cases = {}
    for name, value in [('unknown-format', 'unknown'), ('legacy-v1', 'parrot-reviewed-answers-v1')]:
        bad = copy.deepcopy(fact); bad['format'] = value; cases[name] = bad
    for name, value in [('wrong-mode', 'wholeReply'), ('missing-mode', None)]:
        bad = copy.deepcopy(fact)
        if value is None: bad.pop('mode')
        else: bad['mode'] = value
        cases[name] = bad
    for name, field, value in [('pending-review', 'verdict', 'PENDING_SOURCE_FACT_REVIEW'),
                              ('whole-reply-review', 'verdict', 'PASS_SOURCE_ONLY'),
                              ('blank-reviewer', 'reviewer', '  '),
                              ('blank-date', 'reviewedAt', ''), ('bad-digest', 'digest', 'not-a-digest')]:
        bad = copy.deepcopy(fact); bad['facts'][0]['review'][field] = value; cases[name] = bad
    bad = copy.deepcopy(fact); bad['answers'] = [dict(reply='mixed reply')]; cases['mixed-replies'] = bad
    bad = copy.deepcopy(fact); bad['facts'] = []; cases['empty-facts'] = bad
    for name, value in cases.items(): invoke(name, value, missing_key=True)
    invoke('changed-approved-payload', fact, approved='0'*64, missing_key=True)
    # The CLI validates the independently approved bytes/review-state gate;
    # full source identities/ranges/digests still belong to production import.
print(f'CATALOG SIGNER: {checks} checks; {failures} failures; actual CLI/CryptoKit, synthetic trust only; no app/native acceptance')
raise SystemExit(0 if failures == 0 else 1)

#!/usr/bin/env python3
"""Compile actual setup admission with model-free dependencies; no Keychain calls."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
trace = (root / "Parrot/Services/AnswerTrace.swift").read_text()
start = trace.index("    static func isAllowed(")
end = trace.index("\n    }", start) + len("\n    }")
allowed = "import Foundation\nimport CoreFoundation\nenum AnswerTraceRecorder {\n" + trace[start:end] + "\n}\n"
main = r'''
import Foundation
let qa = "com.uygar.parrot.sat54.qa"
let nonce = "01234567-89AB-4CDE-8FAB-0123456789AB"
var failures = 0
func check(_ name: String, _ pass: Bool) {
    print((pass ? "PASS " : "FAIL ") + name)
    if !pass { failures += 1 }
}
func mode(_ options: [String], id: String? = qa, flag: Any? = true,
          boot: Any? = true, next: Any? = nil) -> QASetupLaunch.Decision {
    QASetupLaunch.decision(arguments: ["Parrot"]+options, bundleID:id, flag:flag,
                           defaultFlag:boot, nextLaunch:next)
}
for phase in ["write","verify-cleanup","absent"] {
    let options = ["--qa-setup","--qa-credential-probe",phase,nonce]
    check("native credential phase admitted only to setup: " + phase, mode(options) == .settingsOnly)
    check("meeting preference cannot activate models for probe: " + phase,
          mode(options,next:false) == .settingsOnly)
    check("production identity rejects probe: " + phase,
          mode(options,id:"com.uygar.parrot",boot:nil) == .rejected)
}
let good = ["--qa-setup","--qa-credential-probe","write",nonce]
check("missing setup flag rejected", mode(Array(good.dropFirst()),boot:nil) == .rejected)
check("production cannot fall through unknown probe", mode(Array(good.dropFirst()),id:"com.uygar.parrot",boot:nil) == .rejected)
check("wrong identity rejected", mode(good,id:qa+".other") == .rejected)
check("missing identity rejected", mode(good,id:nil) == .rejected)
check("numeric trace flag rejected", mode(good,flag:NSNumber(value:1)) == .rejected)
check("false trace flag rejected", mode(good,flag:false) == .rejected)
check("string trace flag rejected", mode(good,flag:"true") == .rejected)
check("missing nonce rejected", mode(Array(good.dropLast())) == .rejected)
check("malformed nonce rejected", mode(["--qa-setup","--qa-credential-probe","write","claude-api-key"]) == .rejected)
check("noncanonical nonce rejected", mode(["--qa-setup","--qa-credential-probe","write",nonce.lowercased()]) == .rejected)
check("unknown phase rejected", mode(["--qa-setup","--qa-credential-probe","delete",nonce]) == .rejected)
check("extra capture flag rejected", mode(good+["--capture-test"]) == .rejected)
check("arbitrary account argument rejected", mode(good+["claude-api-key"]) == .rejected)
check("reordered flags rejected", mode(["--qa-credential-probe","--qa-setup","write",nonce]) == .rejected)
QASetupChecks.run(check)
print("ADMISSION CHECKS: \(failures) failures; source-only")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="parrot-qa-credential-admission-") as directory:
    temp = Path(directory)
    (temp/"Allowed.swift").write_text(allowed)
    (temp/"main.swift").write_text(main)
    files = [temp/"Allowed.swift", root/"Parrot/Services/QASetupLaunch.swift",
             root/"Parrot/ProfileTest+QASetup.swift"]
    policy = root/"Parrot/Services/QACredentialProbePolicy.swift"
    if policy.exists():
        files.append(policy)
    binary = temp/"checks"
    subprocess.run(["swiftc","-swift-version","5",*[str(p) for p in files],
                    str(temp/"main.swift"),"-o",str(binary)],check=True)
    raise SystemExit(subprocess.run([str(binary)],timeout=15).returncode)

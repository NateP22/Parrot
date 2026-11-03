#!/usr/bin/env python3
"""Run the existing fictional form guards against actual routing source only.

This bounded check does not load the app, user data, credentials or models.
It is not a provider score or native acceptance test.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
main = r'''
import Foundation
var checks = 0
var failures = 0
ReviewedFormContextTests.run { name, passed in
    checks += 1
    if !passed {
        failures += 1
        print("FAIL " + name)
    }
}
print("FORM CONTEXT: \(checks) checks; \(failures) failures; source-only, no provider/native acceptance")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="parrot-reviewed-form-context-") as directory:
    temp = Path(directory)
    (temp / "main.swift").write_text(main)
    binary = temp / "checks"
    subprocess.run([
        "swiftc", "-swift-version", "5",
        "-module-cache-path", str(temp / "module-cache"),
        str(root / "Parrot/Services/ReviewedQuestionScope.swift"),
        str(root / "Parrot/ProfileTest+ReviewedFormContext.swift"),
        str(temp / "main.swift"), "-o", str(binary),
    ], check=True, timeout=90)
    raise SystemExit(subprocess.run([str(binary)], timeout=15).returncode)

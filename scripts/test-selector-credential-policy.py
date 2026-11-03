#!/usr/bin/env python3
"""Execute the actual selector key-read block against inert Security shims."""
from pathlib import Path
import os, platform, plistlib, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
selector = (root / "Parrot/ReviewedSelectorEval.swift").read_text()
source = (root / "Parrot/Services/AnalysisProvider.swift").read_text()
start = selector.index("        // Existing own-QA store only;")
end = selector.index("        try await execute(prepared:", start)
block = selector[start:end]
# Preserve the production guard order and execute its unchanged key-read block.
assert selector.index("guard QASetupLaunch.isActive") < selector.index("guard matchesBuild") < selector.index("guard SwitchingAnalysisProvider.liveKind") < start
assert "APIKeyStore.loadInBackground" in block
helper = source[source.index("enum APIKeyStore {"):]
shims = (root / "scripts/credential-regression.swift").read_text().split("var failures = 0")[0]
main = shims + r'''
var legacySetCalls = 0
var legacyGetCalls = 0
let scenario = CommandLine.arguments.last!
func SecKeychainSetUserInteractionAllowed(_ value: Bool) -> OSStatus {
    legacySetCalls += 1
    return scenario == "set-failed" || value ? errSecAuthFailed : errSecSuccess
}
func SecKeychainGetUserInteractionAllowed(_ value: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    legacyGetCalls += 1
    value.pointee = DarwinBoolean(scenario == "still-enabled")
    return scenario == "get-failed" ? errSecAuthFailed : errSecSuccess
}
enum Failure: Error { case key }
@MainActor func selectorKey() async throws -> String {
''' + block + r'''
    return key
}
var failures = 0
func check(_ label: String, _ result: Bool) {
    print((result ? "PASS " : "FAIL ") + label)
    if !result { failures += 1 }
}
Task { @MainActor in
    let fixture = "public-inert-selector-fixture"
    if scenario != "missing" { records["claude-api-key"] = Data(fixture.utf8) }
    if scenario == "locked" { blockedReads["claude-api-key"] = errSecInteractionNotAllowed }
    if scenario == "ordinary-default" {
        check("ordinary background load retains saved key", await APIKeyStore.loadInBackground() == fixture)
        check("ordinary default forbids modern UI", interactionRequests.count == 1 && interactionRequests[0] == true)
        check("ordinary default checks legacy UI suppression", legacyGetCalls > 0)
    } else {
        var received: String?
        do { received = try await selectorKey() } catch { }
        let suppressed = ["set-failed", "get-failed", "still-enabled"].contains(scenario)
        check("unavailable or suppression failure refuses the key", scenario == "success" ? received == fixture : received == nil)
        check("legacy suppression is always requested", legacySetCalls == 1)
        check("legacy readback and actual read suppression are checked", legacyGetCalls == (scenario == "set-failed" ? 0 : (suppressed ? 1 : 2)))
        check("suppression failure never reads a credential", reads.values.reduce(0,+) == (suppressed ? 0 : 1))
        check("every actual selector item query forbids UI", interactionRequests.count == (suppressed ? 0 : 1) && interactionRequests.allSatisfy { $0 == true })
    }
    check("only own QA service is queried", services.allSatisfy { $0 == "com.uygar.parrot.sat54.qa" })
    check("only fixed provider account is read", Set(reads.keys).isSubset(of: ["claude-api-key"]))
    check("read-only policy never writes or deletes", additions.isEmpty && updates.isEmpty && deletions.isEmpty)
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''
with tempfile.TemporaryDirectory(prefix="parrot-selector-credential-policy-") as directory:
    temp = Path(directory)
    (temp / "APIKeyStore.swift").write_text("import Foundation\nimport Security\nimport LocalAuthentication\nimport os\n" + helper)
    (temp / "main.swift").write_text(main)
    binary = temp / "checks"
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(["swiftc", "-D", "PARROT_CUSTOM_LEGACY_SHIMS", "-swift-version", "5", '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk, str(temp / "APIKeyStore.swift"), str(temp / "main.swift"), "-o", str(binary)], check=True, timeout=60)
    undefined = subprocess.check_output(["nm", "-u", str(binary)], text=True, timeout=10)
    for name in ["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecKeychainSetUserInteractionAllowed", "SecKeychainGetUserInteractionAllowed"]:
        assert "_" + name not in undefined, "Refusing real Security function: " + name
    print("Verified no real Security item or interaction function linked", flush=True)
    app = temp / "SelectorPolicy.app"
    executable = app / "Contents/MacOS/checks"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    qa = "com.uygar.parrot.sat54.qa"
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":"checks", "CFBundlePackageType":"APPL", "CFBundleIdentifier":qa, "ParrotKeychainService":qa, "ParrotSessionOnlyCredentials":False}))
    status = 0
    for scenario in ["set-failed", "get-failed", "still-enabled", "missing", "locked", "success", "ordinary-default"]:
        print("Scenario: " + scenario, flush=True)
        result = subprocess.run([str(executable), scenario], capture_output=True, text=True, timeout=10)
        assert "public-inert-selector-fixture" not in result.stdout + result.stderr
        print(result.stdout, end="", flush=True)
        if result.stderr: print("Scenario had diagnostic output; bytes=" + str(len(result.stderr)), flush=True)
        status |= result.returncode
    raise SystemExit(status)

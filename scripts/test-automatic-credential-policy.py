#!/usr/bin/env python3
"""Actual key-store source with fictional records and link-fenced Security calls."""
from pathlib import Path
import platform, plistlib, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Parrot/Services/AnalysisProvider.swift').read_text()
helper = 'import Foundation\nimport Security\nimport LocalAuthentication\nimport os\n' + source[source.index('enum APIKeyStore {'):]
shims = (root / 'scripts/credential-regression.swift').read_text().split('var failures = 0')[0]
main = shims + r'''
var legacyAllowed = true
var legacyValues: [Bool] = []
var legacySetFailure = false
var legacyGetFailure = false
var ignoresDisable = false
var restoreFailure = false
func SecKeychainSetUserInteractionAllowed(_ value: Bool) -> OSStatus {
    legacyValues.append(value)
    if legacySetFailure || (value && restoreFailure) { return errSecAuthFailed }
    if !value && ignoresDisable { return errSecSuccess }
    legacyAllowed = value
    return errSecSuccess
}
func SecKeychainGetUserInteractionAllowed(_ value: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    value.pointee = DarwinBoolean(legacyAllowed)
    return legacyGetFailure ? errSecAuthFailed : errSecSuccess
}
func waitForFixtureEntry(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 2) == .success }
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}
Task {
    records["default-load"] = Data("public-default-fixture".utf8)
    check("default load returns existing own key", APIKeyStore.load(account: "default-load") == "public-default-fixture")
    check("default load forbids modern UI", interactionRequests.last! == true)
    check("default load suppresses legacy UI", legacyValues.contains(false))
    check("legacy state is restored", legacyAllowed)
    records["default-background"] = Data("public-background-fixture".utf8)
    let background = await APIKeyStore.loadInBackground(account: "default-background")
    check("background returns existing own key", background == "public-background-fixture")
    check("background default forbids modern UI", interactionRequests.last! == true)
    _ = APIKeyStore.metadataStatus(account: "default-metadata")
    check("metadata default forbids modern UI", interactionRequests.last! == true)
    legacySetFailure = true
    records["suppression-failed"] = Data("public-suppression-fixture".utf8)
    let before = reads["suppression-failed", default: 0]
    check("suppression failure refuses key", APIKeyStore.load(account: "suppression-failed") == nil)
    check("suppression failure makes no item query", reads["suppression-failed", default: 0] == before)
    legacySetFailure = false
    legacyGetFailure = true
    check("failed legacy state query refuses before item access", APIKeyStore.load(account: "failed-get") == nil && reads["failed-get"] == nil)
    legacyGetFailure = false
    ignoresDisable = true
    check("enabled legacy readback refuses before item access", APIKeyStore.load(account: "still-enabled") == nil && reads["still-enabled"] == nil)
    ignoresDisable = false
    records["failed-restore"] = Data("public-restore-fixture".utf8)
    restoreFailure = true
    check("failed legacy restoration discards returned key", APIKeyStore.load(account: "failed-restore") == nil && !legacyAllowed)
    restoreFailure = false
    legacyAllowed = true
    records["late-delete"] = Data("public-old-fixture".utf8)
    afterRead["late-delete"] = { _ = APIKeyStore.delete(account: "late-delete", allowInteraction: false) }
    check("read cannot return concurrently deleted key", APIKeyStore.load(account: "late-delete") == nil)
    records["late-save"] = Data("public-old-fixture".utf8)
    afterRead["late-save"] = { _ = APIKeyStore.save("public-new-fixture", account: "late-save", allowInteraction: false) }
    check("read returns newer saved key", APIKeyStore.load(account: "late-save") == "public-new-fixture")
    blockedReads["cached-denial"] = errSecInteractionNotAllowed
    check("locked key has an honest authorization status", await APIKeyStore.settingsKey(account: "cached-denial") == .needsAuthorization)
    let deniedCount = reads["cached-denial", default: 0]
    for _ in 0..<10 { _ = await APIKeyStore.settingsKey(account: "cached-denial") }
    check("reopening settings never repeats denied queries", reads["cached-denial", default: 0] == deniedCount)
    records["parallel-load"] = Data("public-parallel-fixture".utf8)
    let successes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<20 { group.addTask { APIKeyStore.load(account: "parallel-load") == "public-parallel-fixture" } }
        var count = 0
        for await ok in group { if ok { count += 1 } }
        return count
    }
    check("concurrent cache misses make one Security read", successes == 20 && reads["parallel-load"] == 1)
    let release = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    _ = APIKeyStore.save("public-cached-fixture", account: "cached-main")
    records["slow-read"] = Data("public-slow-fixture".utf8)
    afterRead["slow-read"] = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    let started = Date()
    let lookup = Task { await APIKeyStore.settingsKey(account: "slow-read", timeoutSeconds: 0.5) }
    let didEnter = await Task.detached { waitForFixtureEntry(entered) }.value
    check("slow fixture actually enters Security operation", didEnter)
    let slow = await lookup.value
    check("blocked Security read does not hold UI waiter", slow == .unavailable && Date().timeIntervalSince(started) < 1.5)
    check("timed-out worker keeps legacy UI disabled", !legacyAllowed)
    let again = await APIKeyStore.settingsKey(account: "slow-read", timeoutSeconds: 0.05)
    check("timeout cannot spawn another key worker", again == .unavailable && reads["slow-read"] == 1)
    let mainStarted = Date()
    let mainResults = await MainActor.run { () -> (Bool, Bool, Bool) in
        (APIKeyStore.load(account: "cached-main") == "public-cached-fixture",
         APIKeyStore.load(account: "uncached-main") == nil,
         APIKeyStore.save("public-main-fixture", account: "main-save") == false)
    }
    check("main actor remains responsive behind stalled read", mainResults.0 && mainResults.1 && mainResults.2 && Date().timeIntervalSince(mainStarted) < 0.5)
    check("busy main save never changes credentials", records["main-save"] == nil && updates["main-save"] == nil)
    records["busy-explicit"] = Data("public-explicit-fixture".utf8)
    let explicit = await APIKeyStore.settingsKey(account: "busy-explicit", requestAuthorization: true, timeoutSeconds: 0.05)
    check("busy explicit authorization is refused immediately", explicit == .unavailable && reads["busy-explicit"] == nil)
    release.signal()
    var eventual: APIKeyStore.SettingsKeyResult = .unavailable
    for _ in 0..<50 {
        eventual = await APIKeyStore.settingsKey(account: "slow-read", timeoutSeconds: 0.05)
        if case .available = eventual { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    var mainLookup: APIKeyStore.SettingsKeyResult = .unavailable
    for _ in 0..<50 {
        mainLookup = await APIKeyStore.settingsKey(account: "uncached-main")
        if mainLookup == .notFound { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    check("completed workers restore original UI policy", eventual == .available("public-slow-fixture") && mainLookup == .notFound && legacyAllowed)
    check("expired or busy authorization cannot prompt later", reads["busy-explicit"] == nil)
    check("own QA service remains isolated", services.allSatisfy { $0 == "com.uygar.parrot.sat54.qa" })
    print("AUTOMATIC KEY POLICY: \(failures) failures; fictional Security only, no native acceptance")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''
with tempfile.TemporaryDirectory(prefix='parrot-automatic-credential-') as folder:
    temp = Path(folder)
    (temp / 'API.swift').write_text(helper)
    (temp / 'main.swift').write_text(main)
    binary = temp / 'checks'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['swiftc', '-D', 'PARROT_CUSTOM_LEGACY_SHIMS', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk, str(temp / 'API.swift'), str(temp / 'main.swift'), '-o', str(binary)], check=True, timeout=60)
    undefined = subprocess.check_output(['nm', '-u', str(binary)], text=True, timeout=10)
    for name in ['SecItemCopyMatching', 'SecItemAdd', 'SecItemUpdate', 'SecItemDelete', 'SecKeychainSetUserInteractionAllowed', 'SecKeychainGetUserInteractionAllowed']:
        assert '_' + name not in undefined, 'Refusing real Security API: ' + name
    app = temp / 'Checks.app'
    executable = app / 'Contents/MacOS/checks'
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    qa = 'com.uygar.parrot.sat54.qa'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'checks', 'CFBundlePackageType': 'APPL', 'CFBundleIdentifier': qa, 'ParrotKeychainService': qa, 'ParrotSessionOnlyCredentials': False}))
    completed = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
    assert not any(value in completed.stdout + completed.stderr for value in ['public-default-fixture', 'public-background-fixture', 'public-old-fixture', 'public-new-fixture'])
    print(completed.stdout, end='')
    raise SystemExit(completed.returncode)

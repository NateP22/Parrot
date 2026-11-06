#!/usr/bin/env python3
"""Actual key-store source with fictional records and link-fenced Security calls."""
from pathlib import Path
import platform, plistlib, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Parrot/Services/AnalysisProvider.swift').read_text()
helper = 'import Foundation\nimport Security\nimport LocalAuthentication\nimport os\n' + source[source.index('enum APIKeyStore {'):]
# Read-only synchronization for the fixture only, appended to the extracted
# helper file. No production API, behavior or Security boundary is changed.
helper += r'''
extension APIKeyStore {
    static func regressionHasSettingsRead(_ account: String) -> Bool {
        pendingSettings.withLock { $0[account] != nil }
    }
    static func regressionLiveSettingsWaiters(_ account: String) -> Int {
        pendingSettings.withLock { reads in
            reads[account]?.waiters.filter { $0.isPending }.count ?? 0
        }
    }
}
'''
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
func waitForState(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
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

    // A settings panel may arrive while startup is already loading the same
    // key. Both ordinary callers should share the result, never a new query.
    records["joined-read"] = Data("public-joined-fixture".utf8)
    let joinedEntered = DispatchSemaphore(value: 0)
    let joinedRelease = DispatchSemaphore(value: 0)
    afterRead["joined-read"] = { joinedEntered.signal(); _ = joinedRelease.wait(timeout: .now() + 5) }
    let joinedOwner = Task { await APIKeyStore.settingsKey(account: "joined-read", timeoutSeconds: 2) }
    check("joined read enters one fictional operation", await Task.detached { waitForFixtureEntry(joinedEntered) }.value)
    let sameAccountAuthorization = await APIKeyStore.settingsKey(account: "joined-read", requestAuthorization: true)
    check("explicit authorization never queues behind same-account read", sameAccountAuthorization == .unavailable)
    let joinedFollower = Task { await APIKeyStore.settingsKey(account: "joined-read", timeoutSeconds: 2) }
    check("both ordinary waiters are registered before release",
          await waitForState { APIKeyStore.regressionLiveSettingsWaiters("joined-read") == 2 })
    joinedRelease.signal()
    let joinedResult = await joinedFollower.value
    let joinedFirst = await joinedOwner.value
    check("overlapping ordinary readers both receive the existing key",
          joinedFirst == .available("public-joined-fixture") && joinedResult == joinedFirst)
    check("joined ordinary callers make exactly one Security query", reads["joined-read"] == 1)

    // Expiration belongs to a waiter, not to the still-running read. A later
    // ordinary waiter must survive an earlier owner's deadline.
    records["queue-blocker"] = Data("public-blocker-fixture".utf8)
    records["queued-survivor"] = Data("public-survivor-fixture".utf8)
    let blockerEntered = DispatchSemaphore(value: 0)
    let blockerRelease = DispatchSemaphore(value: 0)
    afterRead["queue-blocker"] = { blockerEntered.signal(); _ = blockerRelease.wait(timeout: .now() + 5) }
    let blockerOwner = Task { await APIKeyStore.settingsKey(account: "queue-blocker", timeoutSeconds: 2) }
    check("unrelated operation holds the fictional read lock", await Task.detached { waitForFixtureEntry(blockerEntered) }.value)
    let expiredOwner = await APIKeyStore.settingsKey(account: "queued-survivor", timeoutSeconds: 0.05)
    check("queued owner expires independently", expiredOwner == .unavailable && reads["queued-survivor"] == nil)
    let survivingFollower = Task { await APIKeyStore.settingsKey(account: "queued-survivor", timeoutSeconds: 2) }
    check("surviving ordinary waiter is registered before release",
          await waitForState { APIKeyStore.regressionLiveSettingsWaiters("queued-survivor") == 1 })
    blockerRelease.signal()
    let survivor = await survivingFollower.value
    _ = await blockerOwner.value
    check("live joined waiter survives expired ordinary owner",
          survivor == .available("public-survivor-fixture") && reads["queued-survivor"] == 1)

    // Settle this deliberately expired fixture before the next, unrelated
    // explicit-authorization control; a busy try-lock is an allowed refusal.
    var settledSurvivor: APIKeyStore.SettingsKeyResult = .unavailable
    for _ in 0..<50 {
        settledSurvivor = await APIKeyStore.settingsKey(account: "queued-survivor")
        if case .available = settledSurvivor { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    check("queued fixture settles before the next control", settledSurvivor == .available("public-survivor-fixture"))
    check("fictional read lock is released before explicit control",
          APIKeyStore.metadataStatus(account: "settled-barrier") == errSecItemNotFound)

    records["abandon-blocker"] = Data("public-abandon-blocker".utf8)
    records["abandoned-read"] = Data("public-abandoned-fixture".utf8)
    let abandonEntered = DispatchSemaphore(value: 0)
    let abandonRelease = DispatchSemaphore(value: 0)
    afterRead["abandon-blocker"] = { abandonEntered.signal(); _ = abandonRelease.wait(timeout: .now() + 5) }
    let abandonBlocker = Task { await APIKeyStore.settingsKey(account: "abandon-blocker", timeoutSeconds: 2) }
    check("abandon control holds unrelated fictional read",
          await Task.detached { waitForFixtureEntry(abandonEntered) }.value)
    let abandonedOwner = await APIKeyStore.settingsKey(account: "abandoned-read", timeoutSeconds: 0.05)
    let abandonedFollower = await APIKeyStore.settingsKey(account: "abandoned-read", timeoutSeconds: 0.05)
    check("all queued ordinary waiters expire without an item query",
          abandonedOwner == .unavailable && abandonedFollower == .unavailable
          && APIKeyStore.regressionLiveSettingsWaiters("abandoned-read") == 0
          && APIKeyStore.regressionHasSettingsRead("abandoned-read") && reads["abandoned-read"] == nil)
    abandonRelease.signal()
    _ = await abandonBlocker.value
    check("unstarted abandoned cohort is retired",
          await waitForState { !APIKeyStore.regressionHasSettingsRead("abandoned-read") })
    check("retiring abandoned cohort makes no Security query", reads["abandoned-read"] == nil)
    let freshAfterAbandon = await APIKeyStore.settingsKey(account: "abandoned-read")
    check("fresh caller succeeds after abandoned cohort",
          freshAfterAbandon == .available("public-abandoned-fixture") && reads["abandoned-read"] == 1)

    records["denial-blocker"] = Data("public-denial-blocker".utf8)
    blockedReads["joined-denial"] = errSecInteractionNotAllowed
    let denialEntered = DispatchSemaphore(value: 0)
    let denialRelease = DispatchSemaphore(value: 0)
    afterRead["denial-blocker"] = { denialEntered.signal(); _ = denialRelease.wait(timeout: .now() + 5) }
    let denialBlocker = Task { await APIKeyStore.settingsKey(account: "denial-blocker", timeoutSeconds: 2) }
    check("denial control holds unrelated fictional read",
          await Task.detached { waitForFixtureEntry(denialEntered) }.value)
    let denialOwner = Task { await APIKeyStore.settingsKey(account: "joined-denial", timeoutSeconds: 2) }
    check("denial owner is registered", await waitForState { APIKeyStore.regressionLiveSettingsWaiters("joined-denial") == 1 })
    let denialFollower = Task { await APIKeyStore.settingsKey(account: "joined-denial", timeoutSeconds: 2) }
    check("denial follower is registered", await waitForState { APIKeyStore.regressionLiveSettingsWaiters("joined-denial") == 2 })
    denialRelease.signal()
    let firstDenial = await denialOwner.value
    let secondDenial = await denialFollower.value
    _ = await denialBlocker.value
    check("joined denied reads preserve authorization classification",
          firstDenial == .needsAuthorization && secondDenial == .needsAuthorization && reads["joined-denial"] == 1)
    check("joined denial refresh never repeats the read",
          await APIKeyStore.settingsKey(account: "joined-denial") == .needsAuthorization && reads["joined-denial"] == 1)

    records["interactive-owner"] = Data("public-interactive-fixture".utf8)
    let interactiveEntered = DispatchSemaphore(value: 0)
    let interactiveRelease = DispatchSemaphore(value: 0)
    afterRead["interactive-owner"] = { interactiveEntered.signal(); _ = interactiveRelease.wait(timeout: .now() + 5) }
    let interactiveOwner = Task {
        await APIKeyStore.settingsKey(account: "interactive-owner", requestAuthorization: true, timeoutSeconds: 0.05)
    }
    check("explicit fictional read actually starts", await Task.detached { waitForFixtureEntry(interactiveEntered) }.value)
    let ordinaryDeadline = Date()
    let ordinaryJoined = await APIKeyStore.settingsKey(account: "interactive-owner", timeoutSeconds: 0.05)
    check("ordinary waiter keeps its deadline during explicit authorization",
          ordinaryJoined == .unavailable && Date().timeIntervalSince(ordinaryDeadline) < 0.5)
    interactiveRelease.signal()
    check("explicit owner retains its own authorization lifetime",
          await interactiveOwner.value == .available("public-interactive-fixture"))
    check("ordinary joiner cannot create an interactive query", reads["interactive-owner"] == 1)

    records["cold-main-ready"] = Data("public-cold-main-fixture".utf8)
    let coldResult = await MainActor.run { APIKeyStore.load(account: "cold-main-ready") }
    check("cold main read defers without blocking", coldResult == nil)
    let warmedMain = await APIKeyStore.loadInBackground(account: "cold-main-ready")
    check("deferred cold main read becomes available to awaited caller",
          warmedMain == "public-cold-main-fixture" && reads["cold-main-ready"] == 1)
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

import Foundation
import Security
import LocalAuthentication

// These module-local functions replace the imported C API at compile time.
// All records are deliberately fake; no Security API is forwarded to macOS.
var records: [String: Data] = [:]
var blockedReads: [String: OSStatus] = [:]
var failedWrites: Set<String> = []
var raceOnAdd: [String: Data] = [:]
var failedDeletes: Set<String> = []
var reads: [String: Int] = [:]
var deletions: [String: Int] = [:]
var additions: [String: Int] = [:]
var updates: [String: Int] = [:]
var services: [String] = []
var dataRequests: [String: [Bool]] = [:]
var interactionRequests: [Bool?] = []

func account(_ query: CFDictionary) -> String {
    let context = (query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext
    interactionRequests.append(context?.interactionNotAllowed)
    services.append((query as NSDictionary)[kSecAttrService] as! String)
    return (query as NSDictionary)[kSecAttrAccount] as! String
}
func SecItemCopyMatching(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let name = account(query)
    reads[name, default: 0] += 1
    dataRequests[name, default: []].append((query as NSDictionary)[kSecReturnData] as? Bool ?? false)
    if let status = blockedReads[name] { return status }
    guard let value = records[name] else { return errSecItemNotFound }
    output?.pointee = value as NSData
    return errSecSuccess
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    let name = account(query)
    deletions[name, default: 0] += 1
    if failedDeletes.contains(name) { return errSecAuthFailed }
    return records.removeValue(forKey: name) == nil ? errSecItemNotFound : errSecSuccess
}
func SecItemAdd(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let name = account(query)
    additions[name, default: 0] += 1
    if failedWrites.contains(name) { return errSecAuthFailed }
    if let raced = raceOnAdd.removeValue(forKey: name) { records[name] = raced }
    if records[name] != nil { return errSecDuplicateItem }
    records[name] = (query as NSDictionary)[kSecValueData] as? Data
    return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    let name = account(query)
    updates[name, default: 0] += 1
    if failedWrites.contains(name) { return errSecAuthFailed }
    guard records[name] != nil else { return errSecItemNotFound }
    records[name] = (attributes as NSDictionary)[kSecValueData] as? Data
    return errSecSuccess
}

var failures = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS \(name)") }
    else { print("FAIL \(name)"); failures += 1 }
}

if CommandLine.arguments.contains("--no-ui-tests") {
    check("noninteractive metadata reports absence", APIKeyStore.metadataStatus(account:"no-ui",allowInteraction:false)==errSecItemNotFound)
    check("noninteractive atomic add succeeds", APIKeyStore.save("public-no-ui",account:"no-ui",replaceExisting:false,allowInteraction:false))
    records["no-ui-load"]=Data("public-no-ui".utf8)
    check("noninteractive uncached load succeeds", APIKeyStore.load(account:"no-ui-load",allowInteraction:false)=="public-no-ui")
    check("noninteractive delete succeeds", APIKeyStore.delete(account:"no-ui",allowInteraction:false))
    check("every noninteractive item query has a no-UI context", interactionRequests.count==4 && interactionRequests.allSatisfy { $0==true })
    exit(failures==0 ? 0:1)
}

if CommandLine.arguments.contains("--settings-lookup-tests") {
    Task {
        records["settings-ready"] = Data("public-settings-fixture".utf8)
        let ready = await APIKeyStore.settingsKey(account: "settings-ready")
        check("settings loads an existing key without prompting", ready == .available("public-settings-fixture"))
        check("settings startup read supplies a no-UI context", interactionRequests == [true])
        blockedReads["settings-locked"] = errSecInteractionNotAllowed
        let locked = await APIKeyStore.settingsKey(account: "settings-locked")
        check("locked settings read is authorization-needed, never missing", locked == .needsAuthorization)
        let readCount = reads["settings-locked", default: 0]
        _ = await APIKeyStore.settingsKey(account: "settings-locked")
        check("ordinary refresh never retries a cached failed secret read", reads["settings-locked"] == readCount + 1)
        // metadataStatus is deliberately uncached; only that query repeats.
        records["settings-locked"] = Data("public-existing-fixture".utf8)
        blockedReads.removeValue(forKey: "settings-locked")
        let retried = await APIKeyStore.settingsKey(account: "settings-locked", requestAuthorization: true)
        check("explicit retry recovers the same saved key without save", retried == .available("public-existing-fixture"))
        check("explicit retry retains ordinary authorization policy", interactionRequests.last! == nil)
        check("saved-key lookup never adds, updates or deletes credentials", additions.isEmpty && updates.isEmpty && deletions.isEmpty)
        let absent = await APIKeyStore.settingsKey(account: "settings-absent")
        check("no existing record is labelled correctly", absent == .notFound)
        blockedReads["settings-unavailable"] = errSecNotAvailable
        let unavailable = await APIKeyStore.settingsKey(account: "settings-unavailable")
        check("service failure is unavailable, never missing", unavailable == .unavailable)
        let expected = Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as! String
        check("settings reads only its existing own service", services.allSatisfy { $0 == expected })
        exit(failures == 0 ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--invalid-service-tests") {
    check("invalid QA metadata rejects save", !APIKeyStore.save("dummy-isolation", account: "isolated"))
    check("invalid QA metadata cannot load", APIKeyStore.load(account: "isolated") == nil)
    APIKeyStore.delete(account: "isolated")
    check("invalid service metadata is unavailable rather than absent", APIKeyStore.metadataStatus(account: "isolated") == errSecNotAvailable)
    check("invalid QA metadata makes zero Security calls", services.isEmpty)
    print(failures == 0 ? "ALL INVALID SERVICE REGRESSIONS PASS" : "INVALID SERVICE REGRESSION FAILURES: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

if let modeIndex = CommandLine.arguments.firstIndex(of: "--persistence-phase"),
   let path = ProcessInfo.processInfo.environment["PARROT_TEST_FAKE_STORE"] {
    let url = URL(fileURLWithPath: path)
    if let data = try? Data(contentsOf: url) { records = try! JSONDecoder().decode([String: Data].self, from: data) }
    let phase = CommandLine.arguments[modeIndex + 1]
    if phase == "write" {
        check("persistent QA save succeeds", APIKeyStore.save("dummy-restart-only", account: "restart"))
        try! JSONEncoder().encode(records).write(to: url)
    } else {
        check("fresh process reloads saved synthetic credential", APIKeyStore.load(account: "restart") == "dummy-restart-only")
    }
    let expected = Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as! String
    check("restart phase touches only its own service", !services.isEmpty && services.allSatisfy { $0 == expected })
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--session-only-tests") {
    check("session mode is selected by bundle configuration", APIKeyStore.isSessionOnly)
    check("session starts without a key", APIKeyStore.load(account: "session") == nil)
    check("session key can be supplied", APIKeyStore.save("dummy-session", account: "session"))
    check("session key can be used", APIKeyStore.load(account: "session") == "dummy-session")
    check("session create-only cannot replace a key", !APIKeyStore.save("dummy-other", account: "session", replaceExisting: false))
    check("session collision preserves its key", APIKeyStore.load(account: "session") == "dummy-session")
    APIKeyStore.delete(account: "session")
    check("session key can be cleared", APIKeyStore.load(account: "session") == nil)
    check("session metadata cannot claim real persistence", APIKeyStore.metadataStatus(account: "session") == errSecNotAvailable)
    check("session mode makes zero Security calls", reads.isEmpty && additions.isEmpty && updates.isEmpty && deletions.isEmpty)
    check("session mode persists no credential", records.isEmpty)
    print(failures == 0 ? "ALL SESSION CREDENTIAL REGRESSIONS PASS" : "SESSION CREDENTIAL REGRESSION FAILURES: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

for (name, status) in [("denied", errSecAuthFailed), ("cancelled", errSecUserCanceled),
                       ("locked", errSecInteractionNotAllowed)] {
    blockedReads[name] = status
    for _ in 0..<10 { _ = APIKeyStore.load(account: name) }
    check("\(name) access is attempted once per session", reads[name] == 1)
}

records["blank"] = Data("dummy-original".utf8)
check("empty save is rejected", !APIKeyStore.save("", account: "blank"))
check("empty save preserves existing record", records["blank"] == Data("dummy-original".utf8))
check("empty save makes no delete", deletions["blank", default: 0] == 0)

records["failed-write"] = Data("dummy-original".utf8)
failedWrites.insert("failed-write")
check("failed save is reported", !APIKeyStore.save("dummy-new", account: "failed-write"))
check("failed save preserves original record", records["failed-write"] == Data("dummy-original".utf8))

records["replace"] = Data("dummy-original".utf8)
check("existing record can be updated", APIKeyStore.save("dummy-new", account: "replace"))
check("update preserves the record and its ACL", deletions["replace", default: 0] == 0 && updates["replace"] == 1)
check("updated record is cached", APIKeyStore.load(account: "replace") == "dummy-new" && reads["replace", default: 0] == 0)

check("missing record is added", APIKeyStore.save("dummy-added", account: "new") && records["new"] == Data("dummy-added".utf8))

records["delete-failure"] = Data("dummy-original".utf8)
_ = APIKeyStore.load(account: "delete-failure")
failedDeletes.insert("delete-failure")
APIKeyStore.delete(account: "delete-failure")
check("failed delete preserves cached original", APIKeyStore.load(account: "delete-failure") == "dummy-original")

blockedReads.removeValue(forKey: "denied")
check("explicit successful save recovers blocked account", APIKeyStore.save("dummy-recovered", account: "denied") && APIKeyStore.load(account: "denied") == "dummy-recovered")

records["metadata-uncached"] = Data("public-metadata-fixture".utf8)
_ = APIKeyStore.load(account: "metadata-uncached")
check("metadata sees an existing record", APIKeyStore.metadataStatus(account: "metadata-uncached") == errSecSuccess)
records.removeValue(forKey: "metadata-uncached")
check("metadata bypasses cached credential after removal", APIKeyStore.metadataStatus(account: "metadata-uncached") == errSecItemNotFound)
check("metadata only requests attributes, never password data", dataRequests["metadata-uncached"] == [true,false,false])
blockedReads["metadata-blocked"] = errSecInteractionNotAllowed
check("metadata permission refusal is not reported as absent", APIKeyStore.metadataStatus(account: "metadata-blocked") == errSecInteractionNotAllowed)
check("metadata refusal requested no password data", dataRequests["metadata-blocked"] == [false])
records["delete-status"] = Data("public-delete-fixture".utf8)
failedDeletes.insert("delete-status")
check("delete exposes a real failure", APIKeyStore.delete(account: "delete-status") == false)
failedDeletes.remove("delete-status")
check("delete exposes a successful removal", APIKeyStore.delete(account: "delete-status") == true)
check("delete missing item is successful cleanup", APIKeyStore.delete(account: "delete-status") == true)
check("probe metadata starts absent", APIKeyStore.metadataStatus(account: "create-only-race") == errSecItemNotFound)
records["create-only-race"] = Data("public-foreign-collision".utf8)
check("create-only save rejects a concurrent collision", !APIKeyStore.save("public-probe", account: "create-only-race", replaceExisting: false))
check("create-only save preserves the concurrent entry", records["create-only-race"] == Data("public-foreign-collision".utf8))
check("create-only save never invokes update or delete", updates["create-only-race", default:0] == 0 && deletions["create-only-race", default:0] == 0)
check("create-only save adds a missing entry", APIKeyStore.save("public-probe", account: "create-only-new", replaceExisting: false))
check("create-only new entry does not use update", updates["create-only-new", default:0] == 0 && additions["create-only-new"] == 1)

let expectedService = Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as? String ?? "com.uygar.parrot"
check("normal calls preserve the existing interaction query policy", interactionRequests.allSatisfy { $0==nil })
check("all Security operations stay in the configured service", !services.isEmpty && services.allSatisfy { $0 == expectedService })

print(failures == 0 ? "ALL CREDENTIAL REGRESSIONS PASS" : "CREDENTIAL REGRESSION FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)

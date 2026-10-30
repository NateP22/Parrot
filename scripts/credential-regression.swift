import Foundation
import Security

// These module-local functions replace the imported C API at compile time.
// All records are deliberately fake; no Security API is forwarded to macOS.
var records: [String: Data] = [:]
var blockedReads: [String: OSStatus] = [:]
var failedWrites: Set<String> = []
var failedDeletes: Set<String> = []
var reads: [String: Int] = [:]
var deletions: [String: Int] = [:]
var additions: [String: Int] = [:]
var updates: [String: Int] = [:]
var services: [String] = []

func account(_ query: CFDictionary) -> String {
    services.append((query as NSDictionary)[kSecAttrService] as! String)
    return (query as NSDictionary)[kSecAttrAccount] as! String
}
func SecItemCopyMatching(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let name = account(query)
    reads[name, default: 0] += 1
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

if CommandLine.arguments.contains("--invalid-service-tests") {
    check("invalid QA metadata rejects save", !APIKeyStore.save("dummy-isolation", account: "isolated"))
    check("invalid QA metadata cannot load", APIKeyStore.load(account: "isolated") == nil)
    APIKeyStore.delete(account: "isolated")
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
    APIKeyStore.delete(account: "session")
    check("session key can be cleared", APIKeyStore.load(account: "session") == nil)
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

let expectedService = Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as? String ?? "com.uygar.parrot"
check("all Security operations stay in the configured service", !services.isEmpty && services.allSatisfy { $0 == expectedService })

print(failures == 0 ? "ALL CREDENTIAL REGRESSIONS PASS" : "CREDENTIAL REGRESSION FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)

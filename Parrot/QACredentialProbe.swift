import Foundation
import CoreFoundation
import Security

/// QA-only process probe. It never constructs the app, models, audio or meeting store.
enum QACredentialProbe {
    struct Environment {
        let setupActive: Bool
        let bundleID: String?
        let traceFlag: Any?
        let configuredService: String?
        let sessionOnly: Any?
        var isEligible: Bool {
            guard setupActive, bundleID == QASetupLaunch.bundleID,
                  AnswerTraceRecorder.isAllowed(bundleID: bundleID, flag: traceFlag),
                  configuredService == QASetupLaunch.bundleID,
                  let session = sessionOnly as? NSNumber,
                  CFGetTypeID(session) == CFBooleanGetTypeID(), !session.boolValue else { return false }
            return true
        }
    }
    struct Report: Encodable, Sendable {
        let stage: String
        let phase: String
        let nonce: String
        let pid: Int32
        let status: OSStatus?
        let userInteractionDisallowed: Bool
        let cleanupVerified: Bool
        let nativeAcceptance = false
        let scope = "synthetic QA credential component only"
        var succeeded: Bool { ["saved", "verified_removed", "absent"].contains(stage) }
        private enum CodingKeys: String, CodingKey {
            case stage, phase, nonce, pid, status, userInteractionDisallowed
            case cleanupVerified, nativeAcceptance, scope
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(stage, forKey: .stage)
            try values.encode(phase, forKey: .phase)
            try values.encode(nonce, forKey: .nonce)
            try values.encode(pid, forKey: .pid)
            if let status { try values.encode(status, forKey: .status) }
            else { try values.encodeNil(forKey: .status) }
            try values.encode(userInteractionDisallowed, forKey: .userInteractionDisallowed)
            try values.encode(cleanupVerified, forKey: .cleanupVerified)
            try values.encode(nativeAcceptance, forKey: .nativeAcceptance)
            try values.encode(scope, forKey: .scope)
        }
    }
    static func execute(_ request: QACredentialProbePolicy.Request, environment: Environment) -> Report {
        func result(_ stage: String, _ status: OSStatus? = nil, disabled: Bool = false,
                    cleaned: Bool = false) -> Report {
            Report(stage: stage, phase: request.phase.rawValue, nonce: request.nonce.uuidString,
                   pid: ProcessInfo.processInfo.processIdentifier, status: status,
                   userInteractionDisallowed: disabled, cleanupVerified: cleaned)
        }
        guard environment.isEligible else { return result("rejected") }
        // Disable legacy UI in this process. Each item query also supplies a
        // fresh noninteractive authentication context; normal app processes
        // and the existing Keychain backend/access controls are unchanged.
        let setStatus = SecKeychainSetUserInteractionAllowed(false)
        guard setStatus == errSecSuccess else { return result("interaction_refused", setStatus) }
        var interaction = DarwinBoolean(true)
        let getStatus = SecKeychainGetUserInteractionAllowed(&interaction)
        guard getStatus == errSecSuccess, !interaction.boolValue else {
            return result("interaction_refused", getStatus == errSecSuccess ? errSecInteractionNotAllowed : getStatus)
        }
        switch request.phase {
        case .write:
            let status = APIKeyStore.metadataStatus(account: request.account, allowInteraction: false)
            guard status == errSecItemNotFound else {
                return result(status == errSecSuccess ? "collision" : "metadata_refused", status, disabled: true)
            }
            let added = APIKeyStore.createIfAbsent(request.publicFixture, account: request.account, allowInteraction: false)
            guard added == errSecSuccess else {
                return result(added == errSecDuplicateItem ? "collision" : "write_failed", added, disabled: true)
            }
            return result("saved", disabled: true)
        case .verifyCleanup:
            guard let fixture = APIKeyStore.load(account: request.account, allowInteraction: false) else {
                return result("verification_unavailable", disabled: true)
            }
            guard fixture == request.publicFixture else { return result("fixture_mismatch", disabled: true) }
            guard APIKeyStore.delete(account: request.account, allowInteraction: false) else { return result("delete_failed", disabled: true) }
            // A successful delete is not a proof of absence: the runner needs
            // the separate fresh-process metadata phase below.
            return result("verified_removed", disabled: true)
        case .absent:
            let status = APIKeyStore.metadataStatus(account: request.account, allowInteraction: false)
            guard status == errSecItemNotFound else { return result("cleanup_unverified", status, disabled: true) }
            return result("absent", status, disabled: true, cleaned: true)
        }
    }
    static func run() -> Never {
        guard let request = QACredentialProbePolicy.request(options: Array(CommandLine.arguments.dropFirst())) else {
            emit(Report(stage: "rejected", phase: "invalid", nonce: "",
                        pid: ProcessInfo.processInfo.processIdentifier, status: nil,
                        userInteractionDisallowed: false, cleanupVerified: false))
            exit(2)
        }
        let completion = Completion()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            completion.finish(Report(stage: "timeout", phase: request.phase.rawValue,
                nonce: request.nonce.uuidString, pid: ProcessInfo.processInfo.processIdentifier,
                status: nil, userInteractionDisallowed: false, cleanupVerified: false), code: 124)
        }
        DispatchQueue.global(qos: .utility).async {
            let environment = Environment(setupActive: QASetupLaunch.isActive,
                bundleID: Bundle.main.bundleIdentifier,
                traceFlag: Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace"),
                configuredService: Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as? String,
                sessionOnly: Bundle.main.object(forInfoDictionaryKey: "ParrotSessionOnlyCredentials"))
            let report = execute(request, environment: environment)
            completion.finish(report, code: report.succeeded ? 0 : 1)
        }
        dispatchMain()
    }
    private static func emit(_ report: Report) {
        guard let data = try? JSONEncoder().encode(report) else { exit(2) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish(_ report: Report, code: Int32) {
            let winner = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            guard winner else { return }
            emit(report)
            exit(code)
        }
    }
}

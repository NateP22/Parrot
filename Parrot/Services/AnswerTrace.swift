import Foundation
import CoreFoundation
import Darwin

/// One host clock for diagnostics and future ScreenCaptureKit displayTime.
/// Integer conversion truncates by less than one ns; never substitute Date.
enum AnswerTraceClock {
    private static let timebase: mach_timebase_info_data_t? = {
        var value = mach_timebase_info_data_t()
        return mach_timebase_info(&value) == KERN_SUCCESS ? value : nil
    }()

    static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { return nil }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }

    static func nowNs() -> UInt64? {
        nanoseconds(ticks: mach_absolute_time())
    }

    static var timebaseNumerator: UInt32? { timebase?.numer }
    static var timebaseDenominator: UInt32? { timebase?.denom }

    static func nanoseconds(ticks: UInt64) -> UInt64? {
        guard let timebase else { return nil }
        return nanoseconds(ticks: ticks, numerator: timebase.numer, denominator: timebase.denom)
    }
}

enum AnswerTraceSource: String, Codable, Sendable { case me, them }
struct AnswerTraceContext: Codable, Equatable, Sendable {
    let sessionID: UUID
    let questionID: UUID
    let source: AnswerTraceSource
}

/// These are diagnostic callbacks, not proof of audible end or visible pixels.
enum AnswerTraceStage: String, Codable, Sendable {
    case asrFinal, callbackReceived, questionReady, retrievalDone
    case providerStarted, providerReturned, requestSent, responseReceived
    case validated, cardInserted, discarded, providerError
}

struct AnswerTraceRequestIdentity: Codable, Sendable {
    let requestID: UUID
    let profileID: UUID?
    let allowGeneralKnowledge: Bool?
    /// Admitted snapshot identity, not the signed catalog's payload SHA.
    let catalogRevisionToken: String?
}

/// Retained by a request across awaits and redaction; never sent to a model.
struct AnswerTraceLink: Sendable {
    let context: AnswerTraceContext
    let identity: AnswerTraceRequestIdentity
    let recorder: AnswerTraceRecorder

    func mark(_ stage: AnswerTraceStage, model: String? = nil, insightID: UUID? = nil) {
        _ = recorder.mark(context: context, stage: stage, identity: identity, model: model, insightID: insightID)
    }

    func bind(insightID: UUID) {
        if recorder.bind(insightID: insightID, context: context, requestID: identity.requestID) {
            mark(.cardInserted, insightID: insightID)
        }
    }
}

/// Bounded, QA-only private journal. A trace failure never changes an answer.
/// No text, key, URL, profile name, fixture ID or expected answer is recorded.
final class AnswerTraceRecorder: @unchecked Sendable {
    static func isAllowed(bundleID: String?, flag: Any?) -> Bool {
        guard bundleID == "com.uygar.parrot.sat54.qa", let number = flag as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    static let shared: AnswerTraceRecorder = {
        let allowed = isAllowed(bundleID: Bundle.main.bundleIdentifier,
                                flag: Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace"))
        let root = allowed ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Parrot/NativeAnswerTrace", isDirectory: true) : nil
        return AnswerTraceRecorder(enabled: allowed, outputRoot: root)
    }()

    struct Event: Codable, Sendable {
        let context: AnswerTraceContext
        let stage: AnswerTraceStage
        let atNs: UInt64
        let identity: AnswerTraceRequestIdentity?
        let model: String?
        let insightID: UUID?
    }
    struct Binding: Codable, Sendable {
        let insightID: UUID
        let context: AnswerTraceContext
        let requestID: UUID?
    }
    struct Snapshot: Codable, Sendable {
        let schema: String
        let clockDomain: String
        let clockRoundingErrorUpperNs: UInt64
        let clockTimebaseNumerator: UInt32?
        let clockTimebaseDenominator: UInt32?
        let sessionID: UUID?
        let buildCommit: String?
        let events: [Event]
        let bindings: [Binding]
        let droppedEvents: Int
        let rejectedContexts: Int
        let clockErrors: Int
        var writeErrors: Int
        let truncated: Bool
        let finished: Bool
        let nativeAcceptance: Bool
    }

    private let lock = NSLock()
    private let enabled: Bool
    private let outputRoot: URL?
    private let eventLimit: Int
    private let bindingLimit: Int
    private let writer: ((Snapshot, URL) throws -> Void)?
    private var session: UUID?
    private var active = false
    private var events: [Event] = []
    private var bindings: [UUID: Binding] = [:]
    private var droppedEvents = 0, rejectedContexts = 0, clockErrors = 0, writeErrors = 0
    private var truncated = false
    private let buildCommit: String?

    init(enabled: Bool, eventLimit: Int = 4096, bindingLimit: Int = 128, outputRoot: URL? = nil,
         writer: ((Snapshot, URL) throws -> Void)? = nil) {
        self.enabled = enabled
        self.eventLimit = max(1, min(eventLimit, 4096))
        self.bindingLimit = max(1, min(bindingLimit, 128))
        self.outputRoot = outputRoot
        self.writer = writer
        let commit = Bundle.main.object(forInfoDictionaryKey: "ParrotSourceCommit") as? String
        self.buildCommit = commit?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil ? commit : nil
    }

    var sessionID: UUID? { lock.withLock { enabled && active ? session : nil } }

    @discardableResult
    func startSession() -> UUID? {
        lock.withLock {
            guard enabled else { return nil }
            session = UUID(); active = true
            events = []; bindings = [:]
            droppedEvents = 0; rejectedContexts = 0; clockErrors = 0; writeErrors = 0; truncated = false
            return session
        }
    }

    func makeContext(source: AnswerTraceSource, expectedSessionID: UUID?) -> AnswerTraceContext? {
        lock.withLock {
            guard enabled else { return nil }
            guard active, let session, session == expectedSessionID else {
                rejectedContexts += 1; return nil
            }
            return AnswerTraceContext(sessionID: session, questionID: UUID(), source: source)
        }
    }

    func link(context: AnswerTraceContext?, profileID: UUID?, catalogRevisionToken: String?,
              allowGeneralKnowledge: Bool? = nil) -> AnswerTraceLink? {
        guard let context else { return nil }
        return lock.withLock {
            guard enabled else { return nil }
            guard active, session == context.sessionID,
                  catalogRevisionToken == nil || catalogRevisionToken?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                rejectedContexts += 1; return nil
            }
            return AnswerTraceLink(context: context,
                identity: AnswerTraceRequestIdentity(requestID: UUID(), profileID: profileID,
                    allowGeneralKnowledge: allowGeneralKnowledge, catalogRevisionToken: catalogRevisionToken), recorder: self)
        }
    }

    @discardableResult
    func mark(context: AnswerTraceContext, stage: AnswerTraceStage, atNs: UInt64? = nil,
              identity: AnswerTraceRequestIdentity? = nil, model: String? = nil, insightID: UUID? = nil) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            guard active, session == context.sessionID else { rejectedContexts += 1; return false }
            guard let timestamp = atNs ?? AnswerTraceClock.nowNs() else { clockErrors += 1; return false }
            // Only fixed model identifiers, never arbitrary request/settings strings.
            guard model == nil || model == "claude-haiku-5-5" else { rejectedContexts += 1; return false }
            guard events.count < eventLimit else { droppedEvents += 1; truncated = true; return false }
            events.append(Event(context: context, stage: stage, atNs: timestamp,
                                identity: identity, model: model, insightID: insightID))
            return true
        }
    }

    @discardableResult
    func bind(insightID: UUID, context: AnswerTraceContext, requestID: UUID? = nil) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            guard active, session == context.sessionID else { rejectedContexts += 1; return false }
            if let previous = bindings[insightID] {
                guard previous.context == context && previous.requestID == requestID else {
                    rejectedContexts += 1; return false
                }
                return true
            }
            guard bindings.count < bindingLimit else { truncated = true; return false }
            bindings[insightID] = Binding(insightID: insightID, context: context, requestID: requestID)
            return true
        }
    }

    func context(forInsightID id: UUID) -> AnswerTraceContext? { lock.withLock { bindings[id]?.context } }

    private func lockedSnapshot() -> Snapshot {
        Snapshot(schema: "qa-answer-trace-v1", clockDomain: "mach_absolute_time_ns",
                 clockRoundingErrorUpperNs: 1, clockTimebaseNumerator: AnswerTraceClock.timebaseNumerator,
                 clockTimebaseDenominator: AnswerTraceClock.timebaseDenominator,
                 sessionID: session, buildCommit: buildCommit,
                 events: events, bindings: bindings.values.sorted { $0.insightID.uuidString < $1.insightID.uuidString },
                 droppedEvents: droppedEvents, rejectedContexts: rejectedContexts, clockErrors: clockErrors,
                 writeErrors: writeErrors, truncated: truncated, finished: !active, nativeAcceptance: false)
    }

    func snapshot() -> Snapshot { lock.withLock { lockedSnapshot() } }

    @discardableResult
    func finish() -> Snapshot? {
        let frozen: Snapshot? = lock.withLock {
            guard enabled, active else { return nil }
            active = false
            return lockedSnapshot()
        }
        guard let frozen else { return nil }
        var result = frozen
        if let outputRoot, let session = frozen.sessionID {
            do {
                if let writer { try writer(frozen, outputRoot) }
                else {
                    let data = try JSONEncoder().encode(frozen)
                    guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    let destination = outputRoot.appendingPathComponent(session.uuidString + ".json")
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                    try data.write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
            } catch {
                result.writeErrors += 1
                lock.withLock {
                    // A new recording may have started while A's file was
                    // written. Never charge A's failure to recording B.
                    if self.session == frozen.sessionID { writeErrors += 1 }
                }
            }
        }
        return result
    }
}

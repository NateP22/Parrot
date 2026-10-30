import Foundation

enum CapturedAudioBackend: String, Codable, Sendable { case tap, screenCapture, microphone }
struct CapturedAudioClockStamp: Sendable {
    let backend: CapturedAudioBackend
    let hostStartNs: UInt64?
    let hostTicks: UInt64?
    let sourceFrames: UInt32
    let sourceRate: Double
    let sourceSampleTime: Double?
    var sourceClockValue: Int64? = nil
    var sourceClockTimescale: Int32? = nil
}

/// QA-only raw capture/output provenance. No raw audio/text or acoustic claim.
final class AnswerAudioTraceRecorder: @unchecked Sendable {
    static let shared: AnswerAudioTraceRecorder = {
        let allowed = AnswerTraceRecorder.isAllowed(bundleID: Bundle.main.bundleIdentifier,
            flag: Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace"))
        let root = allowed ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Parrot/NativeAnswerTrace", isDirectory: true) : nil
        return AnswerAudioTraceRecorder(enabled: allowed, outputRoot: root)
    }()

    struct Span: Codable, Sendable {
        let source: AnswerTraceSource
        let backend: CapturedAudioBackend?
        let hostStartNs: UInt64?
        let rawHostTicks: UInt64?
        let sourceFrames: UInt32?
        let sourceRateHz: UInt32?
        let sourceSampleTime: Double?
        let sourceClockValue: Int64?
        let sourceClockTimescale: Int32?
        let callbackNs: UInt64?
        let outputStart: UInt64
        let paddingBefore: UInt64
        let outputFrames: UInt32
        let outputRateHz: UInt32?
        let rawDurationUpperNs: UInt64?
        let requiresCalibration: Bool
        let invalid: Bool
    }
    struct Snapshot: Codable, Sendable {
        let sessionID: UUID?
        let spans: [Span]
        let invalidSpans: Int
        let rejectedContexts: Int
        let truncated: Bool
        var writeErrors: Int
        let finished: Bool
        let schema: String
        let calibrationVerified: Bool
        let persistedAudioVerified: Bool
        let nativeAcceptance: Bool
    }
    private let lock = NSLock()
    private let enabled: Bool
    private let spanLimit: Int
    private let outputRoot: URL?
    private let writer: ((Snapshot, URL) throws -> Void)?
    private var sessionID: UUID?
    private var active = false
    private var spans: [Span] = []
    private var previous: [String: Span] = [:]
    private var invalidSpans = 0, rejectedContexts = 0, writeErrors = 0
    private var truncated = false

    init(enabled: Bool, spanLimit: Int = 32_768, outputRoot: URL? = nil,
         writer: ((Snapshot, URL) throws -> Void)? = nil) {
        self.enabled = enabled
        self.spanLimit = max(1, min(spanLimit, 32_768))
        self.outputRoot = outputRoot
        self.writer = writer
    }
    var isEnabled: Bool { enabled }
    func start(sessionID: UUID?) {
        lock.withLock {
            guard enabled else { return }
            self.sessionID = sessionID; active = sessionID != nil
            spans = []; previous = [:]; invalidSpans = 0; rejectedContexts = 0
            writeErrors = 0; truncated = false
        }
    }
    private static func rate(_ value: Double) -> UInt32? {
        guard value.isFinite, value > 0, value <= Double(UInt32.max), value.rounded() == value else { return nil }
        return UInt32(value)
    }
    @discardableResult func record(sessionID: UUID?, source: AnswerTraceSource,
        stamp: CapturedAudioClockStamp?, outputStart: UInt64, paddingBefore: UInt64,
        outputFrames: UInt32, outputRate: Double, callbackNs: UInt64?) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            guard active, let sessionID, self.sessionID == sessionID else {
                rejectedContexts += 1; return false
            }
            guard spans.count < spanLimit else { truncated = true; return false }
            let inputRate = stamp.flatMap { Self.rate($0.sourceRate) }
            let outputRateHz = Self.rate(outputRate)
            let sampleTime = stamp?.sourceSampleTime.flatMap { $0.isFinite ? $0 : nil }
            let duration = inputRate.flatMap { rate -> UInt64? in
                guard let frames = stamp?.sourceFrames, frames > 0 else { return nil }
                let numerator = UInt64(frames) * 1_000_000_000
                return numerator / UInt64(rate) + (numerator % UInt64(rate) == 0 ? 0 : 1)
            }
            var invalid = stamp == nil || stamp?.hostStartNs == nil || duration == nil ||
                outputRateHz == nil || outputFrames == 0 || callbackNs == nil || outputStart < paddingBefore
            if stamp?.backend == .tap || stamp?.backend == .microphone {
                invalid = invalid || sampleTime == nil
            }
            if stamp?.sourceSampleTime != nil && sampleTime == nil { invalid = true }
            let (_, outputOverflow) = outputStart.addingReportingOverflow(UInt64(outputFrames))
            invalid = invalid || outputOverflow
            if let start = stamp?.hostStartNs, let duration {
                invalid = invalid || start.addingReportingOverflow(duration).overflow ||
                    (callbackNs.map { $0 < start } ?? true)
            }
            if let old = previous[source.rawValue] {
                if let start = stamp?.hostStartNs, let oldStart = old.hostStartNs, let oldDuration = old.rawDurationUpperNs {
                    let oldEnd = oldStart.addingReportingOverflow(oldDuration)
                    let quantum = inputRate.map { (1_000_000_000 + UInt64($0) - 1) / UInt64($0) } ?? 0
                    let tolerance = oldEnd.partialValue.addingReportingOverflow(quantum)
                    let overlaps = start < oldEnd.partialValue && oldEnd.partialValue - start > quantum
                    if start <= oldStart || overlaps || oldEnd.overflow || tolerance.overflow || start > tolerance.partialValue { invalid = true }
                }
                let oldOutputEnd = old.outputStart.addingReportingOverflow(UInt64(old.outputFrames))
                let expectedOutput = oldOutputEnd.partialValue.addingReportingOverflow(paddingBefore)
                if oldOutputEnd.overflow || expectedOutput.overflow || outputStart != expectedOutput.partialValue ||
                    old.backend != stamp?.backend || old.sourceRateHz != inputRate { invalid = true }
                if let oldSample = old.sourceSampleTime, let oldFrames = old.sourceFrames, let sampleTime,
                   abs(sampleTime - oldSample - Double(oldFrames)) > 1 { invalid = true }
            }
            let row = Span(source: source, backend: stamp?.backend, hostStartNs: stamp?.hostStartNs,
                rawHostTicks: stamp?.hostTicks, sourceFrames: stamp?.sourceFrames, sourceRateHz: inputRate,
                sourceSampleTime: sampleTime, sourceClockValue: stamp?.sourceClockValue,
                sourceClockTimescale: stamp?.sourceClockTimescale, callbackNs: callbackNs,
                outputStart: outputStart, paddingBefore: paddingBefore, outputFrames: outputFrames,
                outputRateHz: outputRateHz, rawDurationUpperNs: duration,
                requiresCalibration: true, invalid: invalid)
            spans.append(row); previous[source.rawValue] = row
            if invalid { invalidSpans += 1 }
            return !invalid
        }
    }
    private func snapshotLocked() -> Snapshot {
        Snapshot(sessionID: sessionID, spans: spans, invalidSpans: invalidSpans,
                 rejectedContexts: rejectedContexts, truncated: truncated, writeErrors: writeErrors,
                 finished: !active, schema: "parrot-raw-audio-clock-v1", calibrationVerified: false,
                 persistedAudioVerified: false, nativeAcceptance: false)
    }
    func snapshot() -> Snapshot {
        lock.withLock { snapshotLocked() }
    }
    @discardableResult func finish() -> Snapshot {
        let ready: Snapshot? = lock.withLock {
            guard enabled && active else { return nil }
            active = false
            return snapshotLocked()
        }
        guard var frozen = ready else { return snapshot() }
        guard enabled, let id = frozen.sessionID, let outputRoot else { return frozen }
        if let writer {
            do { try writer(frozen, outputRoot.appendingPathComponent(id.uuidString + "-audio.json")) }
            catch {
                frozen.writeErrors += 1
                lock.withLock { if sessionID == frozen.sessionID { writeErrors += 1 } }
            }
            return frozen
        }
        do {
            let data = try JSONEncoder().encode(frozen)
            guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = outputRoot.appendingPathComponent(id.uuidString + "-audio.json")
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard try Data(contentsOf: file) == data else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            frozen.writeErrors += 1
            lock.withLock { if sessionID == frozen.sessionID { writeErrors += 1 } }
        }
        return frozen
    }
}

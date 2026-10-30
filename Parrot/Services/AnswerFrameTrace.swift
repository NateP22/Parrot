import Foundation

/// One-shot result with an independent deadline. Late SDK callbacks are ignored.
enum AnswerFrameDeadline {
    static func value<Value: Sendable>(seconds: Double,
        request: (@escaping @Sendable (Value?) -> Void) -> Void) async -> Value? {
        await withCheckedContinuation { continuation in
            let once=AnswerFrameResultOnce<Value>(continuation)
            let delay=seconds.isFinite ? max(0.001,min(seconds,12)) : 12
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+delay) { once.resolve(nil) }
            request { once.resolve($0) }
        }
    }
}
private final class AnswerFrameResultOnce<Value: Sendable>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Value?,Never>?
    init(_ continuation: CheckedContinuation<Value?,Never>) { self.continuation=continuation }
    func resolve(_ value: Value?) {
        let ready=lock.withLock { let ready=continuation; continuation=nil; return ready }
        ready?.resume(returning:value)
    }
}

/// Main-actor-owned capture lifecycle, separated from OS callbacks for tests.
struct AnswerFrameLifecycle {
    enum Phase { case idle, waiting, starting, running, stopping, failedLocked }
    private(set) var phase = Phase.idle
    private(set) var sessionID: UUID?
    private(set) var generation: UUID?
    mutating func begin(sessionID: UUID) -> UUID? {
        guard phase == .idle else { return nil }
        self.sessionID=sessionID; generation=UUID(); phase = .waiting; return generation
    }
    mutating func start(generation: UUID) -> Bool {
        guard self.generation == generation, phase == .waiting else { return false }
        phase = .starting; return true
    }
    mutating func activate(generation: UUID) -> Bool {
        guard self.generation == generation, phase == .starting else { return false }
        phase = .running; return true
    }
    mutating func beginStop() -> UUID? {
        guard phase != .idle && phase != .stopping, let generation else { return nil }
        phase = .stopping; return generation
    }
    mutating func finishStop(generation: UUID, knownStopped: Bool) -> Bool {
        guard self.generation == generation, phase == .stopping || phase == .failedLocked else { return false }
        guard knownStopped else { phase = .failedLocked; return true }
        phase = .idle; sessionID=nil; self.generation=nil; return true
    }
}

enum AnswerFrameOwner {
    static func matches(windowID: UInt32, requestedID: UInt32, ownerPID: Int32?, ownPID: Int32, onScreen: Bool) -> Bool {
        requestedID > 0 && windowID == requestedID && ownPID > 0 && ownerPID == ownPID && onScreen
    }
}
enum AnswerFrameStatus: String, Codable, Sendable { case complete, idle, blank, suspended, started, stopped, unknown }
struct AnswerFrameObservation: Codable, Sendable {
    var status: AnswerFrameStatus
    var displayTicks: UInt64?
    var displayNs: UInt64?
    var callbackNs: UInt64?
    var rect: [Double]
    var scaleFactor: Double?
    var contentScale: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var mediaFrameIndex: Int?
    var mediaPTS: Int64?
}
final class AnswerFrameTraceRecorder: @unchecked Sendable {
    struct Snapshot: Codable, Sendable {
        let sessionID: UUID?
        let windowID: UInt32?
        let observations: [AnswerFrameObservation]
        let invalidFrames: Int
        let rejectedContexts: Int
        let truncated: Bool
        let writeErrors: Int
        let clockDomain: String
        let clockRoundingErrorUpperNs: UInt64
        let independentVisibilityVerified: Bool
        let nativeAcceptance: Bool
    }
    private let lock = NSLock()
    private let enabled: Bool
    private let frameLimit: Int
    private var sessionID: UUID?
    private var windowID: UInt32?
    private var active = false
    private var observations: [AnswerFrameObservation] = []
    private var firstDisplayNs: UInt64?, lastDisplayNs: UInt64?
    private var lastGeometry: AnswerFrameObservation?
    private var encodedFrames = 0, invalidFrames = 0, rejectedContexts = 0, writeErrors = 0
    private var truncated = false
    private var stopExpected = false

    init(enabled: Bool, frameLimit: Int = 36_000) {
        self.enabled = enabled
        self.frameLimit = max(1,min(frameLimit,36_000))
    }
    func start(sessionID: UUID, windowID: UInt32) {
        lock.withLock {
            guard enabled, windowID > 0 else { return }
            self.sessionID = sessionID; self.windowID = windowID; active = true
            observations = []; firstDisplayNs = nil; lastDisplayNs = nil; lastGeometry = nil
            encodedFrames = 0; invalidFrames = 0; rejectedContexts = 0; writeErrors = 0; truncated = false
            stopExpected = false
        }
    }
    var hasCapacity: Bool { lock.withLock { enabled && active && observations.count < frameLimit } }
    static func hasCompleteMetadata(_ frame: AnswerFrameObservation) -> Bool {
        guard frame.status == .complete, let ticks = frame.displayTicks, ticks > 0,
              let ns = frame.displayNs, let callback = frame.callbackNs, ns <= callback,
              frame.rect.count == 4, frame.rect.allSatisfy(\.isFinite),
              frame.rect[0] >= 0, frame.rect[1] >= 0, frame.rect[2] > 0, frame.rect[3] > 0,
              let scale = frame.scaleFactor, scale.isFinite, scale >= 1, scale <= 4,
              let contentScale = frame.contentScale, contentScale.isFinite, contentScale > 0, contentScale <= 4,
              let width = frame.pixelWidth, let height = frame.pixelHeight,
              width > 0, height > 0, width <= 4096, height <= 4096 else { return false }
        return (frame.rect[0]+frame.rect[2])*scale <= Double(width)+1 &&
            (frame.rect[1]+frame.rect[3])*scale <= Double(height)+1
    }
    @discardableResult func record(sessionID: UUID, frame original: AnswerFrameObservation) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            guard active, self.sessionID == sessionID else { rejectedContexts += 1; return false }
            guard observations.count < frameLimit else { truncated = true; return false }
            var frame = original
            var valid = frame.status != .unknown
            if frame.status == .blank || frame.status == .suspended || (frame.status == .stopped && !stopExpected) {
                valid = false
            }
            var candidate = false
            if frame.status == .complete {
                valid = Self.hasCompleteMetadata(frame)
                if let ns = frame.displayNs {
                    if let lastDisplayNs, ns <= lastDisplayNs { valid = false }
                    if firstDisplayNs == nil { firstDisplayNs = ns }
                    if let firstDisplayNs, ns >= firstDisplayNs, ns - firstDisplayNs <= UInt64(Int64.max) {
                        if frame.mediaPTS != Int64(ns-firstDisplayNs) { valid = false }
                    } else { valid = false }
                    lastDisplayNs = ns
                }
                if frame.mediaFrameIndex != encodedFrames { valid = false }
                if frame.mediaFrameIndex != nil { encodedFrames += 1 }
                if let previous = lastGeometry,
                   previous.rect != frame.rect || previous.scaleFactor != frame.scaleFactor ||
                    previous.contentScale != frame.contentScale || previous.pixelWidth != frame.pixelWidth ||
                    previous.pixelHeight != frame.pixelHeight { valid = false }
                lastGeometry = frame
                candidate = valid
            } else if frame.mediaFrameIndex != nil || frame.mediaPTS != nil {
                // Idle is a status observation, never a fresh retained picture.
                valid = false
            }
            if !valid { invalidFrames += 1 }
            // Invalid raw numbers remain an explicit error, never JSON NaN.
            frame.rect = frame.rect.map { $0.isFinite ? $0 : 0 }
            if frame.scaleFactor?.isFinite == false { frame.scaleFactor = nil }
            if frame.contentScale?.isFinite == false { frame.contentScale = nil }
            observations.append(frame)
            return candidate
        }
    }
    @discardableResult func noteWriteError(sessionID: UUID) -> Bool {
        lock.withLock { guard enabled, self.sessionID == sessionID else { return false }; writeErrors += 1; return true }
    }
    @discardableResult func noteTruncated(sessionID: UUID) -> Bool {
        lock.withLock { guard enabled, self.sessionID == sessionID else { return false }; truncated = true; return true }
    }
    func expectStop(sessionID: UUID) {
        lock.withLock { if enabled && self.sessionID == sessionID { stopExpected = true } }
    }
    func stop() { lock.withLock { active = false } }
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(sessionID: sessionID, windowID: windowID, observations: observations,
                invalidFrames: invalidFrames, rejectedContexts: rejectedContexts, truncated: truncated,
                writeErrors: writeErrors, clockDomain: "mach_absolute_time_ns", clockRoundingErrorUpperNs: 1,
                independentVisibilityVerified: false, nativeAcceptance: false)
        }
    }
}

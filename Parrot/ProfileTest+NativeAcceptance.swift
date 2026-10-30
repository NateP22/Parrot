import Foundation

/// Synthetic diagnostic tracing; no capture, provider, keys or persistent store.
enum NativeAcceptanceTraceTests {
    static func run(_ check: (String, Bool) -> Void) {
        check("trace policy rejects production", !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot", flag: true))
        check("trace policy rejects string flag", !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: "true"))
        check("trace policy rejects absent flag", !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: nil))
        check("trace policy rejects numeric flag", !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: NSNumber(value: 1)))
        check("trace policy accepts actual plist boolean", AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: NSNumber(value: true)))
        check("trace policy rejects false and child identity", !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: false)
              && !AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa.child", flag: true))
        check("trace policy allows only explicit QA", AnswerTraceRecorder.isAllowed(bundleID: "com.uygar.parrot.sat54.qa", flag: true))
        let off = AnswerTraceRecorder(enabled: false)
        check("disabled trace creates no session", off.startSession() == nil)
        check("disabled trace produces no context", off.makeContext(source: .them, expectedSessionID: UUID()) == nil)
        check("disabled trace holds no events", off.snapshot().events.isEmpty)

        let recorder = AnswerTraceRecorder(enabled: true)
        guard let session = recorder.startSession(),
              let first = recorder.makeContext(source: .them, expectedSessionID: session),
              let second = recorder.makeContext(source: .them, expectedSessionID: session) else {
            check("trace creates a session and contexts", false); return
        }
        check("trace questions have distinct runtime IDs", first.questionID != second.questionID)
        check("trace context retains session", first.sessionID == session && second.sessionID == session)
        check("trace records ASR readiness", recorder.mark(context: first, stage: .asrFinal, atNs: 1))
        check("trace records a second question", recorder.mark(context: second, stage: .questionReady, atNs: 2))
        let oldInsight = UUID(), newInsight = UUID()
        check("out of order completion binds original question", recorder.bind(insightID: newInsight, context: second)
              && recorder.bind(insightID: oldInsight, context: first)
              && recorder.context(forInsightID: oldInsight) == first
              && recorder.context(forInsightID: newInsight) == second)
        check("ambiguous insight rebinding rejected", !recorder.bind(insightID: oldInsight, context: second))
        check("rejected binding is sticky", recorder.snapshot().rejectedContexts == 1)
        _ = recorder.startSession()
        check("old session cannot mark new session", !recorder.mark(context: first, stage: .cardInserted, atNs: 3))
        check("old session cannot be relabeled", recorder.makeContext(source: .them, expectedSessionID: session) == nil)
        check("old insight not carried into next session", recorder.context(forInsightID: oldInsight) == nil)

        let identityRecorder = AnswerTraceRecorder(enabled: true)
        let identitySession = identityRecorder.startSession()!
        let identityContext = identityRecorder.makeContext(source: .them, expectedSessionID: identitySession)!
        let profileID = UUID(), token = String(repeating: "a", count: 64)
        let link = identityRecorder.link(context: identityContext, profileID: profileID, catalogRevisionToken: token,
                                          allowGeneralKnowledge: false)
        check("request identity freezes profile and snapshot token", link?.identity.profileID == profileID && link?.identity.catalogRevisionToken == token)
        check("request identity freezes knowledge policy", link?.identity.allowGeneralKnowledge == false)
        check("trace identity rejects free-form catalog strings", identityRecorder.link(context: identityContext, profileID: profileID, catalogRevisionToken: "private text") == nil)
        check("trace metadata rejects arbitrary model strings", !identityRecorder.mark(context: identityContext, stage: .requestSent, model: "private text"))
        check("trace exports clock timebase", identityRecorder.snapshot().clockTimebaseNumerator != nil
              && identityRecorder.snapshot().clockTimebaseDenominator != nil)

        let bounded = AnswerTraceRecorder(enabled: true, eventLimit: 2, bindingLimit: 1)
        let boundedSession = bounded.startSession()!
        let context = bounded.makeContext(source: .them, expectedSessionID: boundedSession)!
        _ = bounded.mark(context: context, stage: .asrFinal, atNs: 1)
        _ = bounded.mark(context: context, stage: .questionReady, atNs: 2)
        check("trace cap fails without overwriting first event", !bounded.mark(context: context, stage: .validated, atNs: 3)
              && bounded.snapshot().events.count == 2 && bounded.snapshot().events.first?.stage == .asrFinal)
        check("trace drop counter stays visible", bounded.snapshot().droppedEvents == 1 && bounded.snapshot().truncated)
        _ = bounded.bind(insightID: UUID(), context: context)
        check("binding cap does not evict earlier identity", !bounded.bind(insightID: UUID(), context: context)
              && bounded.snapshot().bindings.count == 1 && bounded.snapshot().truncated)
        let finished = bounded.finish()
        check("finish is diagnostic only", finished?.finished == true && finished?.nativeAcceptance == false)
        check("post Stop event cannot enter finished trial", !bounded.mark(context: context, stage: .cardInserted, atNs: 4))

        // An old writer is allowed to finish after a new recording starts.
        // Its failure belongs to the frozen old journal, never the new one.
        var rollover: AnswerTraceRecorder!
        rollover = AnswerTraceRecorder(enabled: true, outputRoot: URL(fileURLWithPath: "/unwritten-synthetic-trace"),
            writer: { _, _ in
                _ = rollover.startSession()
                throw CocoaError(.fileWriteNoPermission)
            })
        let priorSession = rollover.startSession()
        let priorResult = rollover.finish()
        check("finish returns original session across rollover", priorResult?.sessionID == priorSession && priorResult?.finished == true)
        check("writer failure stays with original session", priorResult?.writeErrors == 1
              && rollover.snapshot().sessionID != priorSession && rollover.snapshot().writeErrors == 0)
        rollover = nil  // break the test-only writer's captured-variable cycle

        check("Mach rational clock is integer", AnswerTraceClock.nanoseconds(ticks: 3, numerator: 125, denominator: 3) == 125)
        check("Mach conversion truncates by less than one ns", AnswerTraceClock.nanoseconds(ticks: 1, numerator: 125, denominator: 3) == 41)
        check("Mach zero denominator rejected", AnswerTraceClock.nanoseconds(ticks: 1, numerator: 1, denominator: 0) == nil)
        check("Mach overflow rejected", AnswerTraceClock.nanoseconds(ticks: .max, numerator: 2, denominator: 1) == nil)
        check("Mach UInt64 exact bound retained", AnswerTraceClock.nanoseconds(ticks: .max, numerator: 1, denominator: 1) == .max)
    }
}

#if !ANSWER_TRACE_STANDALONE
extension NativeAcceptanceTraceTests {
    private final class GatedProvider: AnalysisProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AnalysisRequest] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        var received: [AnalysisRequest] { lock.withLock { requests } }
        var isConfigured: Bool { true }
        func release() {
            let pending = lock.withLock { released = true; let value = gate; gate = nil; return value }
            pending?.resume()
        }
        func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
            let first = lock.withLock { requests.append(request); return requests.count == 1 }
            if first {
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock {
                        if released { return true }; gate = continuation; return false
                    }
                    if ready { continuation.resume() }
                }
            }
            return AnalysisResult(insights: [InsightDraft(kindKey: "suggestion", title: "Trace fixture",
                detail: "Synthetic trace fixture.", source: nil, reply: "Use the fictional Export control.",
                answerKey: request.currentQuestion)], sentiment: [:], read: nil, coach: nil, resolved: [])
        }
        func summarize(transcript: String, insightTitles: [String], bookmarks: [String], instructions: String,
                       counterpart: String, template: ReportTemplate) async throws -> String { "" }
        func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                            counterpart: String, template: ReportTemplate) async throws -> String { "" }
        func complete(system: String, user: String, maxTokens: Int) async throws -> String { "" }
    }

    @MainActor static func runEngine(_ check: (String, Bool) -> Void) {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: "copilotEnabled"), oldPace = defaults.object(forKey: "copilotPace")
        defer {
            if let oldEnabled { defaults.set(oldEnabled, forKey: "copilotEnabled") } else { defaults.removeObject(forKey: "copilotEnabled") }
            if let oldPace { defaults.set(oldPace, forKey: "copilotPace") } else { defaults.removeObject(forKey: "copilotPace") }
        }
        defaults.set(true, forKey: "copilotEnabled"); defaults.set("fast", forKey: "copilotPace")
        let recorder = AnswerTraceRecorder(enabled: true), provider = GatedProvider()
        let engine = CallAnalysisEngine(provider: provider, answerTraceRecorder: recorder)
        let profile = CallProfile(name: "Trace fixture", iconSystemName: "doc", summary: "Synthetic",
            isBuiltIn: false, sortOrder: 0, persona: "Fixture", tone: "", allowGeneralKnowledge: true,
            kinds: [ProfileKind(id: UUID(), key: "suggestion", label: "Suggestion", colorHex: "808080",
                iconSystemName: "doc", triggerDescription: "Answer", isPinned: false, priority: 1)], gauges: [])
        let session = recorder.startSession()!
        engine.start(profile: profile)
        defer { provider.release(); engine.stop(); _ = recorder.finish() }
        func wait(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date.now + seconds
            while !done() && Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
        }
        let first = recorder.makeContext(source: .them, expectedSessionID: session)!
        let question = "Which fictional export control preserves links?"
        var inserted: [(UUID, AnswerTraceContext?)] = []
        engine.onInsightInserted = { inserted.append(($0.id, recorder.context(forInsightID: $0.id))) }
        engine.ingest(text: question, at: 1, source: .them, answerTraceContext: first)
        wait(3) { !provider.received.isEmpty }
        // Creating another context while the first provider awaits must never
        // relabel the first request or its eventual inserted card.
        let second = recorder.makeContext(source: .them, expectedSessionID: session)!
        provider.release()
        wait(3) { !inserted.isEmpty }
        check("actual engine preserves request context across await", provider.received.first?.answerTrace?.context == first)
        check("actual insertion binds before observer callback", inserted.first?.1 == first)
        check("actual trace keeps request profile identity", provider.received.first?.answerTrace?.identity.profileID == profile.id)
        check("actual insertion has diagnostic card event", recorder.snapshot().events.contains { $0.context == first && $0.stage == .cardInserted })
        if let request = provider.received.first {
            var redactor = Redactor()
            let copy = redactor.redact(request)
            check("redaction preserves local trace identity", copy.answerTrace?.context == first
                  && copy.answerTrace?.identity.requestID == request.answerTrace?.identity.requestID)
        } else { check("redaction preserves local trace identity", false) }
        // Same words again, followed by a non-question. Selection must retain
        // the new qualifying segment, not search by text or use the last callback.
        engine.ingest(text: question, at: 2, source: .them, answerTraceContext: second)
        let ambient = recorder.makeContext(source: .them, expectedSessionID: session)!
        engine.ingest(text: "The fictional document is open.", at: 3, source: .them, answerTraceContext: ambient)
        wait(11) { provider.received.count >= 2 }
        check("identical question uses its own segment context", provider.received.dropFirst().first?.answerTrace?.context == second)
    }
}
#endif

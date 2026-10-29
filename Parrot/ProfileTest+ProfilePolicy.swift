import Foundation

/// Synthetic delayed-provider tests of the actual engine's delivery boundary.
/// No network, microphone, persisted profiles or meeting store is used.
enum ProfilePolicyTests {
    private final class GatedProvider: AnalysisProvider, @unchecked Sendable {
        enum FirstOutcome { case answer, missingKey, transportError }
        private let lock = NSLock()
        private var modes: [Bool] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        private let usesQuestionIdentity: Bool
        private let firstOutcome: FirstOutcome
        init(usesQuestionIdentity: Bool = true, firstOutcome: FirstOutcome = .answer) {
            self.usesQuestionIdentity = usesQuestionIdentity
            self.firstOutcome = firstOutcome
        }
        var requestedModes: [Bool] { lock.withLock { modes } }
        var isConfigured: Bool { true }

        func release() {
            let pending = lock.withLock {
                released = true
                let pending = gate
                gate = nil
                return pending
            }
            pending?.resume()
        }

        func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
            let first = lock.withLock {
                modes.append(request.allowGeneralKnowledge)
                return modes.count == 1
            }
            if first {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock {
                        if released { return true }
                        gate = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
                switch firstOutcome {
                case .answer: break
                case .missingKey: throw AnalysisError.missingAPIKey
                case .transportError: throw URLError(.timedOut)
                }
            }
            guard request.allowGeneralKnowledge else {
                return AnalysisResult(insights: [], sentiment: [:], read: nil, coach: nil, resolved: [])
            }
            return AnalysisResult(insights: [InsightDraft(kindKey: "suggestion", title: "General fixture",
                detail: "Synthetic general advice.", source: "general knowledge",
                reply: "General fixture reply", answerKey: usesQuestionIdentity ? request.currentQuestion : nil)],
                sentiment: ["score": 77], read: "General fixture read",
                coach: "General fixture coaching", resolved: ["Open fixture"])
        }
        func summarize(transcript: String, insightTitles: [String], bookmarks: [String],
                       instructions: String, counterpart: String, template: ReportTemplate) async throws -> String { "" }
        func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                            counterpart: String, template: ReportTemplate) async throws -> String { "" }
        func complete(system: String, user: String, maxTokens: Int) async throws -> String { "" }
    }

    private static func profile(_ name: String) -> CallProfile {
        CallProfile(name: name, iconSystemName: "doc", summary: "Synthetic policy test",
            isBuiltIn: false, sortOrder: 0, persona: "Fixture", tone: "", allowGeneralKnowledge: true,
            kinds: [ProfileKind(id: UUID(), key: "suggestion", label: "Suggestion", colorHex: "808080",
                iconSystemName: "doc", triggerDescription: "Answer the question", isPinned: false, priority: 1)],
            gauges: [SentimentGauge(id: UUID(), key: "score", label: "Score", lowLabel: "Low",
                highLabel: "High", colorHex: "808080")])
    }

    @MainActor
    static func run(_ check: (String, Bool) -> Void) {
        let defaults = UserDefaults.standard
        let keys = ["copilotEnabled", "copilotPace", CloudGate.globalKey, "copilotProvider"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, before) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "copilotEnabled")
        defaults.set("fast", forKey: "copilotPace")
        defaults.set(false, forKey: CloudGate.globalKey)
        defaults.set("claude", forKey: "copilotProvider")
        func wait(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date.now + seconds
            while !done() && Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
        }

        let ai = GatedProvider()
        let engine = CallAnalysisEngine(provider: ai)
        let current = profile("Current fixture")
        engine.start(profile: current)
        let open = Insight(kindKey: "question", title: "Open fixture", detail: "Unanswered fixture", callTime: 0, source: nil)
        engine.seedForSnapshot(profile: current, insights: [open], sentiment: [:], read: nil, meSeconds: 0, themSeconds: 0)
        var publishedGeneral = 0
        var publishedScores: [Int] = []
        engine.onInsightInserted = { if $0.source == "general knowledge" { publishedGeneral += 1 } }
        engine.onPassCompleted = { if let score = $0.values["score"] { publishedScores.append(score) } }
        engine.ingest(text: "Which export option preserves hyperlinks?", at: 1, source: .them)
        wait(2) { ai.requestedModes.count == 1 }
        check("profile policy: permissive request reaches the controlled gate", ai.requestedModes == [true])
        current.allowGeneralKnowledge = false
        ai.release()
        wait(3) { ai.requestedModes.count >= 2 && engine.status == .listening }
        check("profile policy: in-flight general reply cannot cross a switch to strict",
              !engine.insights.contains { $0.source == "general knowledge" })
        check("profile policy: old sentiment/read/coaching cannot cross a switch to strict",
              engine.sentiment.isEmpty && engine.sentimentRead == nil && engine.coachLine == nil)
        check("profile policy: same pending question is requeued under strict policy", ai.requestedModes == [true, false])
        check("profile policy: stale resolution cannot mark an open item handled",
              engine.insights.first { $0.id == open.id }?.isHandled == false)
        check("profile policy: stale result never publishes a card or score", publishedGeneral == 0 && publishedScores.isEmpty)
        engine.stop()

        // Editing a different profile object must not discard an authorized
        // answer under the profile this call actually started with.
        let unchangedAI = GatedProvider()
        let unchangedEngine = CallAnalysisEngine(provider: unchangedAI)
        let unchanged = profile("Active fixture")
        unchangedEngine.start(profile: unchanged)
        unchangedEngine.ingest(text: "Which export option preserves hyperlinks?", at: 1, source: .them)
        wait(2) { unchangedAI.requestedModes.count == 1 }
        let nextCall = profile("Other fixture")
        nextCall.allowGeneralKnowledge = false
        unchangedAI.release()
        wait(2) { unchangedEngine.insights.count == 1 }
        check("profile policy: editing another profile keeps this call's profile", unchangedEngine.activeProfile?.id == unchanged.id)
        check("profile policy: unchanged authorized result still arrives",
              unchangedEngine.insights.first?.reply == "General fixture reply" && unchangedAI.requestedModes == [true])
        unchangedEngine.stop()
        testDedupAwait(check)
        testProviderError(check)
    }

    @MainActor
    private static func testProviderError(_ check: (String, Bool) -> Void) {
        func wait(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date.now + seconds
            while !done() && Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
        }
        for outcome: GatedProvider.FirstOutcome in [.missingKey, .transportError] {
            let ai = GatedProvider(firstOutcome: outcome)
            let engine = CallAnalysisEngine(provider: ai)
            let current = profile("Error fixture")
            engine.start(profile: current)
            engine.ingest(text: "Which export option preserves hyperlinks?", at: 1, source: .them)
            wait(2) { ai.requestedModes.count == 1 }
            check("profile policy: throwing provider reaches gate: \(outcome)", ai.requestedModes == [true])
            current.allowGeneralKnowledge = false
            ai.release()
            wait(2) { ai.requestedModes.count >= 2 && engine.status == .listening }
            check("profile policy: old-policy provider error requeues under strict mode: \(outcome)",
                  ai.requestedModes == [true, false] && engine.status == .listening && engine.insights.isEmpty)
            engine.stop()

            let unchangedAI = GatedProvider(firstOutcome: outcome)
            let unchangedEngine = CallAnalysisEngine(provider: unchangedAI)
            unchangedEngine.start(profile: profile("Unchanged error fixture"))
            unchangedEngine.ingest(text: "Which export option preserves hyperlinks?", at: 1, source: .them)
            wait(2) { unchangedAI.requestedModes.count == 1 }
            unchangedAI.release()
            func hasExpectedError() -> Bool {
                switch (outcome, unchangedEngine.status) {
                case (.missingKey, .needsAPIKey), (.transportError, .error): return true
                default: return false
                }
            }
            wait(2) { hasExpectedError() }
            check("profile policy: unchanged provider error is surfaced without retry: \(outcome)",
                  unchangedAI.requestedModes == [true] && hasExpectedError())
            unchangedEngine.stop()
        }
    }

    /// The session is intercepted completely; warm-up returns immediately and
    /// the same-issue response waits until the test has changed the live mode.
    private final class GatedMatcherProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var pending: GatedMatcherProtocol?
        static var isWaiting: Bool { lock.withLock { pending != nil } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let questions = json?["questions"] as? [String: Any] ?? [:]
            if questions.keys.contains("p0") { Self.lock.withLock { Self.pending = self } }
            else { respond(#"{"answers":{"c0":{"noul":0.0}}}"#) }
        }
        override func stopLoading() {
            Self.lock.withLock { if Self.pending === self { Self.pending = nil } }
        }
        private func respond(_ body: String) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        static func release() {
            let value = lock.withLock { let value = pending; pending = nil; return value }
            value?.respond(#"{"answers":{"p0":{"noul":0.0}}}"#)
        }
    }

    @MainActor
    private static func testDedupAwait(_ check: (String, Bool) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedMatcherProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { GatedMatcherProtocol.release(); session.invalidateAndCancel() }
        let ai = GatedProvider(usesQuestionIdentity: false)
        let engine = CallAnalysisEngine(provider: ai)
        let current = profile("Dedup fixture")
        let kb = KnowledgeBaseService(persistent: false)
        kb.seedForSnapshot(documents: [KBDocument(name: "Synthetic.md", chunkCount: 0, addedAt: .now)])
        engine.knowledgeBase = kb
        engine.docMatcher = JevDocMatcher(apiKey: "synthetic-test-key", session: session)
        engine.start(profile: current)
        let open = Insight(kindKey: "question", title: "Open fixture", detail: "Unanswered fixture", callTime: 0, source: nil)
        let other = Insight(kindKey: "question", title: "Unrelated fixture", detail: "Another open topic", callTime: 0, source: nil)
        engine.seedForSnapshot(profile: current, insights: [open, other], sentiment: [:], read: nil, meSeconds: 0, themSeconds: 0)
        var publishedGeneral = 0
        var publishedScores: [Int] = []
        engine.onInsightInserted = { if $0.source == "general knowledge" { publishedGeneral += 1 } }
        engine.onPassCompleted = { if let score = $0.values["score"] { publishedScores.append(score) } }
        func wait(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date.now + seconds
            while !done() && Date.now < deadline { RunLoop.main.run(until: .now + 0.005) }
        }
        engine.ingest(text: "Which export option preserves hyperlinks?", at: 1, source: .them)
        wait(2) { ai.requestedModes.count == 1 }
        ai.release()
        wait(2) { GatedMatcherProtocol.isWaiting }
        check("profile policy: actual same-issue matcher reaches its controlled gate", GatedMatcherProtocol.isWaiting)
        check("profile policy: awaiting dedup leaves resolution and mood uncommitted",
              engine.insights.first { $0.id == open.id }?.isHandled == false &&
              engine.sentiment.isEmpty && engine.coachLine == nil && engine.sentimentRead == nil)
        check("profile policy: awaiting dedup has published no new cards or score",
              engine.insights.count == 2 && publishedGeneral == 0 && publishedScores.isEmpty)
        current.allowGeneralKnowledge = false
        GatedMatcherProtocol.release()
        wait(3) { ai.requestedModes.count >= 2 && engine.status == .listening }
        check("profile policy: change during dedup discards the stale card",
              !engine.insights.contains { $0.source == "general knowledge" } && publishedGeneral == 0)
        check("profile policy: change during dedup preserves the open resolution target",
              engine.insights.first { $0.id == open.id }?.isHandled == false)
        check("profile policy: change during dedup never publishes old score or coaching",
              publishedScores.isEmpty && engine.sentiment.isEmpty && engine.coachLine == nil && engine.sentimentRead == nil)
        check("profile policy: change during dedup requeues the question under strict policy", ai.requestedModes == [true, false])
        engine.stop()
    }
}

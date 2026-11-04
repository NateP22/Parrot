import Foundation
import SwiftData

/// Fictional source, real KB/provider/redaction/store paths. No real API, key,
/// microphone, app UI or model judgment; never count this as native acceptance.
enum RepositoryKnowledgeTests {
    @MainActor
    static func runSync(_ check: @escaping (String, Bool) -> Void) {
        var finished = false
        let task = Task {
            do { try await run(check) }
            catch { check("repository integration: \(error)", false) }
            finished = true
        }
        let deadline = Date.now + 15
        while !finished && Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
        if !finished { task.cancel() }
        check("repository integration completes", finished)
    }

    static func fixture() throws -> Data {
        let values = [("client/settings.json", "{\"includeLinks\":false}\n"),
                      ("host/settings.json", "{\"includeLinks\":true}\n"),
                      ("host/pageLinks.js", "// Fictional Atlas\nfunction pageLinks(enabled) {\n  if (!enabled) return [];\n  return links;\n}\n// Contact atlas@fictional.example\n"),
                      ("server/pageLinks.js", "function pageLinks() { return links; }\n")]
        return try JSONEncoder().encode(RepositoryKnowledge(schemaVersion: 1,
            repository: "fictional/atlas", requestedRef: "main", commit: String(repeating: "a", count: 40),
            files: values.map { path, text in
                .init(path: path, blob: RepositoryKnowledge.gitBlob(Data(text.utf8)),
                      sha256: RepositoryKnowledge.digest(Data(text.utf8)), text: text)
            }, runtimeScopes: [.init(id: "desktop", name: "Desktop", roots: ["host/", "client/"],
                entryPoints: ["host/pageLinks.js"], dependencyRoots: []),
                .init(id: "web", name: "Web", roots: ["server/"], entryPoints: ["server/pageLinks.js"], dependencyRoots: [])]))
    }

    @MainActor
    private static func run(_ check: (String, Bool) -> Void) async throws {
        let data = try fixture()
        let kb = KnowledgeBaseService(persistent: false)
        try kb.installReviewedCatalog(ReviewedAnswerTests.fixtureData)
        check("repository: old catalog preserved before import", kb.reviewedAnswerSnapshot(for: nil) != nil)
        try kb.installRepositorySource(data)
        let revision = kb.repositoryRevision!
        let trace = AnswerTraceRecorder(enabled: true)
        let sessionID = trace.startSession()
        let context = trace.makeContext(source: .them, expectedSessionID: sessionID)
        let linked = trace.link(context: context, profileID: nil, catalogRevisionToken: nil,
            allowGeneralKnowledge: false, repositoryRevision: revision)
        check("repository: trace pins repository revision", linked?.identity.repositoryRevision == revision)
        check("repository: trace rejects arbitrary source strings", trace.link(context: context,
            profileID: nil, catalogRevisionToken: nil, repositoryRevision: "untrusted file path") == nil)
        check("repository: explicit import bypasses catalog", kb.reviewedAnswerSnapshot(for: nil) == nil)
        let noScope = await kb.search(query: "page links enabled", topK: 6)
        check("repository: missing runtime cannot use secondary documents or guess", noScope.isEmpty && kb.repositoryScopeIssue(for: nil) != nil)
        let unknownScope = await kb.search(query: "page links enabled", runtimeScopeID: "missing", topK: 6)
        check("repository: unknown runtime fails closed", unknownScope.isEmpty)
        let refs = await kb.search(query: "page links enabled", runtimeScopeID: "desktop", topK: 6)
        let followup = CallAnalysisEngine.repositoryRetrievalQuery(question: "How do I do that?",
            recent: ["I want page links disabled.", "How do I do that?"])
        let followupRefs = await kb.search(query: followup, runtimeScopeID: "desktop", topK: 6)
        check("repository: follow-up retains implementation referent", followupRefs.first?.repositoryCitation?.path == "host/pageLinks.js")
        check("repository: actual code retrieval", refs.first?.repositoryCitation?.path == "host/pageLinks.js")
        check("repository: JSON distinct paths in source inventory", kb.documentsInPlay(for: nil).contains("fictional/atlas/client/settings.json") && kb.documentsInPlay(for: nil).contains("fictional/atlas/host/settings.json"))
        do { try kb.installRepositorySource(Data("invalid".utf8)); check("repository: invalid replacement refused", false) }
        catch { check("repository: invalid replacement preserves revision", kb.repositoryRevision == revision) }
        var request = AnalysisRequest(transcript: "Them: Can page links be disabled? Contact atlas@fictional.example.",
            currentQuestion: "Can page links be disabled?", knownInsightTitles: [],
            references: refs + [KBReference(documentName: "Fictional supporting guide", note: nil, text: "Use the visibility control in the panel.")],
            instructions: "", callBrief: "", allowGeneralKnowledge: false,
            knownDocumentNames: kb.documentsInPlay(for: nil) + ["Fictional supporting guide"],
            persona: "", counterpart: "client", kinds: [ProfileKind(id: UUID(), key: "suggestion",
                label: "Suggestion", colorHex: "808080", iconSystemName: "doc",
                triggerDescription: "Answer the question", isPinned: false, priority: 1)],
            gauges: [], repositoryRevision: revision, repositoryRuntimeScopeID: "desktop")
        request.reviewedCatalog = try ReviewedAnswerCatalog.decode(ReviewedAnswerTests.fixtureData)
            .admitted(documents: [], folders: [], profileID: nil)
        request = request.preparingReviewedFacts()
        check("repository: request explicitly clears old catalog", request.usesRepository && request.reviewedCatalog == nil)
        var redactor = Redactor(hideNames: false)
        let redacted = redactor.redact(request)
        check("repository: redaction keeps source revision", redacted.repositoryRevision == revision)
        check("repository: redaction keeps frozen runtime", redacted.repositoryRuntimeScopeID == "desktop")
        check("repository: redaction keeps typed provenance", redacted.references.first?.repositoryCitation == refs.first?.repositoryCitation)
        check("repository: redaction hides private strings", !redacted.transcript.contains("atlas@fictional.example"))

        let defaults = UserDefaults.standard
        let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = before
        func set(_ value: Any, forKey key: String) {
            settings[key] = value
            defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        }
        defer { defaults.setVolatileDomain(before, forName: UserDefaults.argumentDomain) }
        set("claude", forKey: "copilotProvider")
        set(true, forKey: Redactor.enabledKey)
        set(false, forKey: Redactor.namesKey)
        set(false, forKey: CloudGate.globalKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RepositoryFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = ClaudeAnalysisProvider(session: session, keyProvider: { "fictional-inert-key" })
        let switching = SwitchingAnalysisProvider(claude: provider)
        RepositoryFixtureProtocol.bodies = []
        let answer = try await switching.analyze(request).insights.first
        check("repository: actual switcher makes generation and review", RepositoryFixtureProtocol.bodies.count == 2)
        for body in RepositoryFixtureProtocol.bodies {
            check("repository: both requests carry code priority", body.contains("implementation_code") && body.contains("secondary_document") && body.contains("PRIMARY"))
            check("repository: no private email sent", !body.contains("atlas@fictional.example"))
        }
        check("repository: returned answer has canonical code citation", answer?.repositoryCitations == [refs[0].repositoryCitation!])
        check("repository: returned original evidence restored", answer?.evidenceQuote == refs[0].text)
        check("repository: no fake model citation", answer?.repositoryCitations?.first?.url.fragment?.hasPrefix("L1-L") == true)

        for text in [Optional<String>.none, "", "   "] {
            var ambient = request; ambient.currentQuestion = text
            let count = RepositoryFixtureProtocol.bodies.count
            let result = try await switching.analyze(ambient)
            check("repository: ambient claims/network held", result.insights.isEmpty && RepositoryFixtureProtocol.bodies.count == count)
        }
        var local = request; local.forceLocal = true
        let count = RepositoryFixtureProtocol.bodies.count
        let localAnswer = try await switching.analyze(local)
        check("repository: private mode never bypassed", localAnswer.insights.first?.source == nil && RepositoryFixtureProtocol.bodies.count == count)
        let scoped = try await CloudGate.$scopeLocal.withValue(true) { try await switching.analyze(request) }
        check("repository: scoped local stays local", scoped.insights.first?.source == nil && RepositoryFixtureProtocol.bodies.count == count)
        set(true, forKey: CloudGate.globalKey)
        let global = try await switching.analyze(request)
        check("repository: global local stays local", global.insights.first?.source == nil && RepositoryFixtureProtocol.bodies.count == count)
        set(false, forKey: CloudGate.globalKey)
        set("custom", forKey: "copilotProvider")
        let unsupported = try await switching.analyze(request)
        check("repository: unsupported backend fails closed", unsupported.insights.first?.source == nil && RepositoryFixtureProtocol.bodies.count == count)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-code-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("index.json")
        let stored = KnowledgeBaseService(persistent: true, storageURL: index)
        try stored.installRepositorySource(data)
        let reopened = KnowledgeBaseService(persistent: true, storageURL: index)
        let loadDeadline = Date.now + 2
        while reopened.repositoryLoading && Date.now < loadDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        check("repository: source survives reopen", reopened.repositorySource?.commit == kb.repositorySource?.commit)
        let reopenedReferences = await reopened.search(query: "page links enabled", runtimeScopeID: "desktop", topK: 6)
        check("repository: runtime metadata and structural index survive reopen", reopened.repositoryScopeIssue(for: "desktop") == nil && reopenedReferences.contains { $0.text.contains("if (!enabled)") })
        try FileManager.default.removeItem(at: folder.appendingPathComponent("repository-source.parrotrepo"))
        let missing = KnowledgeBaseService(persistent: true, storageURL: index)
        let missingDeadline = Date.now + 2
        while missing.repositoryLoading && Date.now < missingDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        check("repository: missing source retains strict intent", missing.repositoryRevision != nil && missing.repositorySource == nil && missing.reviewedAnswerSnapshot(for: nil) == nil)
        check("repository: missing source retrieval stays empty", await missing.search(query: "page links").isEmpty)
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("repository-source.parrotrepo"))
        let corrupt = KnowledgeBaseService(persistent: true, storageURL: index)
        let corruptDeadline = Date.now + 2
        while corrupt.repositoryLoading && Date.now < corruptDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        check("repository: corrupt source retains strict intent", corrupt.repositoryRevision != nil && corrupt.repositorySource == nil)
        try data.write(to: folder.appendingPathComponent("repository-source.parrotrepo"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("repository-source.parrotrepo.required"))
        _ = KnowledgeBaseService(persistent: true, storageURL: index)
        check("repository: older snapshot gains durable intent", FileManager.default.fileExists(atPath: folder.appendingPathComponent("repository-source.parrotrepo.required").path))

        let faultFolder = folder.appendingPathComponent("marker-fault")
        try FileManager.default.createDirectory(at: faultFolder.appendingPathComponent("repository-source.parrotrepo.required"), withIntermediateDirectories: true)
        let fault = KnowledgeBaseService(persistent: true, storageURL: faultFolder.appendingPathComponent("index.json"))
        do { try fault.installRepositorySource(data); check("repository: marker fault refuses import", false) }
        catch {
            check("repository: marker fault keeps strict runtime", fault.repositoryRevision != nil && fault.repositorySource == nil)
            check("repository: marker fault never publishes source", !FileManager.default.fileExists(atPath: faultFolder.appendingPathComponent("repository-source.parrotrepo").path))
        }

        let citation = refs[0].repositoryCitation!
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let store = ModelConfiguration("Code citations", schema: schema, url: folder.appendingPathComponent("code.store"), cloudKitDatabase: .none)
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [store])
            let context = ModelContext(container)
            context.insert(CallInsight(from: Insight(kindKey: "suggestion", title: "Code", detail: "LOCAL_CODE_ONLY", callTime: 0, source: citation.sourceName, reply: "Turn off page links.", repositoryCitations: [citation])))
            let profile = CallProfile(name: "Runtime fixture", iconSystemName: "doc", summary: "",
                isBuiltIn: false, sortOrder: 0, persona: "", tone: "", allowGeneralKnowledge: false,
                kinds: request.kinds, gauges: [])
            profile.repositoryRuntimeScopeID = "desktop"
            context.insert(profile)
            let exported = try ProfileFile.decode(ProfileFile.encode(profile))
            check("repository profile: portable file preserves runtime", exported.profile.repositoryRuntimeScopeID == "desktop")
            var cleared = exported; cleared.profile.repositoryRuntimeScopeID = nil
            check("repository profile: clearing runtime survives raw-field preservation", try ProfileFile.decode(cleared.data()).profile.repositoryRuntimeScopeID == nil)
            var oldJSON = try JSONSerialization.jsonObject(with: ProfileFile.encode(profile)) as! [String: Any]
            var oldContents = oldJSON["profile"] as! [String: Any]
            oldContents.removeValue(forKey: "repositoryRuntimeScopeID"); oldContents["futureField"] = "retained"
            oldJSON["profile"] = oldContents
            let oldFile = try ProfileFile.decode(JSONSerialization.data(withJSONObject: oldJSON))
            check("repository profile: old portable file decodes to unselected runtime", oldFile.profile.repositoryRuntimeScopeID == nil)
            check("repository profile: unrelated future fields preserved", String(decoding: oldFile.data(), as: UTF8.self).contains("futureField"))
            let profiles = ProfileStore()
            let copy = profiles.duplicate(profile, in: context)
            check("repository profile: duplicate preserves runtime", copy.repositoryRuntimeScopeID == "desktop")
            let imported = profiles.add(exported, source: "user", in: context)
            check("repository profile: import preserves runtime", imported.repositoryRuntimeScopeID == "desktop")
            profile.saveVersion(label: "Desktop")
            let desktopVersion = profile.versions.last!
            profiles.apply(cleared, to: profile, label: "Clear runtime", in: context)
            check("repository profile: apply can clear runtime", profile.repositoryRuntimeScopeID == nil)
            profiles.restore(desktopVersion, of: profile, in: context)
            check("repository profile: restore preserves runtime", profile.repositoryRuntimeScopeID == "desktop")
            try context.save()
        }
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [store])
            let rows = try ModelContext(container).fetch(FetchDescriptor<CallInsight>())
            check("repository: typed citations survive disk reopen", rows.first?.repositoryCitations == [citation])
            let runtimeProfiles = try ModelContext(container).fetch(FetchDescriptor<CallProfile>())
            check("repository profile: selected runtime persists on disk", runtimeProfiles.count == 3 && runtimeProfiles.allSatisfy { $0.repositoryRuntimeScopeID == "desktop" })
        }
        let receipt = ClaudeAnalysisProvider.reportInsightReceipt(kind: "suggestion", title: "Code", source: citation.sourceName, reply: "Turn off page links.", cardDetail: "LOCAL_CODE_ONLY", repositoryCitations: [citation])
        check("repository: report cites commit without exporting raw code", receipt.contains(citation.commit) && !receipt.contains("LOCAL_CODE_ONLY"))
    }
}

private final class RepositoryFixtureProtocol: URLProtocol {
    static var bodies: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let body = String(decoding: data, as: UTF8.self)
        Self.bodies.append(body)
        let review = body.contains("available_evidence")
        let value: [String: Any] = review
            ? ["supported": true, "answers_question": true, "preserves_conditions": true, "clear_and_sayable": true,
               "missing_conditions": [], "unclear_terms": [], "evidence_ids": ["p0"]]
            : ["reply": "Turn off page links.", "evidence_ids": ["p0"]]
        let bytes = ReviewedTransportTests.envelope(value)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

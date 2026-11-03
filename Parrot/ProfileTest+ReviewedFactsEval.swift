import Foundation

/// Fictional transport only. It cannot reach the network or read a real key.
final class FactEvalMockProtocol: URLProtocol {
    static var behavior = 0
    static var bodies: [Data] = []
    static var timeoutAttempts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
        }
        Self.bodies.append(bytes)
        if Self.behavior == 3 {
            Self.timeoutAttempts += 1
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? String ?? ""
        let payload = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
        let review = payload?["answer"] != nil
        let value: [String: Any] = review ? [
            "supported": true, "answers_question": Self.behavior != 2, "preserves_conditions": true,
            "clear_and_sayable": true, "missing_conditions": [], "unclear_terms": [], "evidence_ids": ["p0"]
        ] : ["reply": "In Atlas 4.2, once the draft is saved, choose File > Export.", "evidence_ids": ["p0"]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ReviewedTransportTests.envelope(value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ReviewedFactsEvalChecks {
    // Public, independently reviewed fictional fixture signed with the existing
    // library root. No private signing material is present in source or CI.
    static let fixtureData = Data(base64Encoded: "eyJmb3JtYXQiOiJwYXJyb3QtcmV2aWV3ZWQtZmFjdHMtc2lnbmVkLXYxIiwicGF5bG9hZCI6ImV5Smhibk4zWlhKeklqcGJYU3dpWm1GamRITWlPbHQ3SW1Gd2NHeHBZMkZpYVd4cGRIa2lPaUpGZUhCdmNuUnBibWNnWVNCellYWmxaQ0JrY21GbWRDQnBiaUJtYVdOMGFXOXVZV3dnUVhSc1lYTWdOQzR5TGlJc0ltRjFkR2h2Y21sMGVTSTZJbkJ5YjJSMVkzUklaV3h3SWl3aVkyRjBaV2R2Y25raU9pSndjbTlrZFdOMFEyOXVkSEp2YkNJc0ltTnNZV2x0SWpvaVFYUnNZWE1nTkM0eUlHVjRjRzl5ZEhNZ2MyRjJaV1FnWkhKaFpuUnpJSGRwZEdnZ1JtbHNaU0ErSUVWNGNHOXlkQzRpTENKamIyNWthWFJwYjI1eklqcGJJbFJvWlNCa2NtRm1kQ0JvWVhNZ1ltVmxiaUJ6WVhabFpDNGlYU3dpWkc5amRXMWxiblJsWkZCeWIyUjFZM1JXWlhKemFXOXVJam9pTkM0eUlpd2laWFpwWkdWdVkyVWlPbnNpWlc1a1ZWUkdPQ0k2T0RFc0luRjFiM1JsSWpvaVFYUnNZWE1nTkM0eU9pQkZlSEJ2Y25RZ1lTQnpZWFpsWkNCa2NtRm1kQ0JtY205dElFWnBiR1VnUGlCRmVIQnZjblFnZDJobGJpQjBhR1VnWkhKaFpuUWdhR0Z6SUdKbFpXNGdjMkYyWldRdUlpd2ljMjkxY21ObFNVUWlPaUp6TFdGbU9UUmxOalprTnpNMVl6YzBaR0kzWWpVeU9UazNZbVEyT1RNNFlqQTJaREk1T1RreU5ERXpNVEl6WkdNM01ETTNZVEkxWmpabU1EZGpNMk01TldFaUxDSnpkR0Z5ZEZWVVJqZ2lPakI5TENKbGVHTnNkV1JsWkZOamIzQmxjeUk2V3lKRWIyVnpJRzV2ZENCa1pYTmpjbWxpWlNCd2RXSnNhWE5vYVc1bklHRnVJSFZ1YzJGMlpXUWdaSEpoWm5RdUlsMHNJbWxrSWpvaVppMDJPR1E0TURCbFpUSTFOREEwTlRJek5qQm1OVFU1TkdVaUxDSnlaWEYxYVhKbFpFTnNhV1Z1ZEVOdmJuUmxlSFFpT2x0ZExDSnlaWFpwWlhjaU9uc2laR2xuWlhOMElqb2lOamhrT0RBd1pXVXlOVFF3TkRVeU16WXdaalUxT1RSbFpqWTFaRE5sTURJNFpXVTRNemxpWVdWalpqQXdaV1UyT1RBek56RTNZVFZoTWpObE9UQmpNaUlzSW5KbGRtbGxkMlZrUVhRaU9pSXlNREkyTFRFeExUQXpJaXdpY21WMmFXVjNaWElpT2lKSmJtUmxjR1Z1WkdWdWRDQnpiM1Z5WTJVZ1kzSnBkR2xqT3lCemVXNTBhR1YwYVdNZ2RHVnpkQ0JtYVhoMGRYSmxJRzl1YkhraUxDSjJaWEprYVdOMElqb2lVRUZUVTE5VFQxVlNRMFZmUmtGRFZDSjlMQ0p6WTI5d1pVdGxlU0k2SW1GMGJHRnpMbk5oZG1Wa0xXUnlZV1owTFdWNGNHOXlkQ0lzSW5OdmRYSmpaVkpsZG1semFXOXVJam9pWm1samRHbHZibUZzTFhJeElpd2ljMjkxY21ObFUwaEJNalUySWpvaVkyWmpaakF6WkdKa1pXRmlNRGhpTlRRMlpEQXpaVEptT0dWbU1EZ3lObVptWVdReU1qQTNaakJtTlRJd05EVTFPVEZsT0Raa05tSXpOMk0zWVRjeE5TSjlYU3dpWm05eWJXRjBJam9pY0dGeWNtOTBMWEpsZG1sbGQyVmtMV1poWTNSekxYWXhJaXdpYlc5a1pTSTZJbkpsZG1sbGQyVmtSbUZqZEhNaUxDSnpiM1Z5WTJWeklqcGJleUpoZFhSb2IzSnBkSGtpT2lKd2NtOWtkV04wU0dWc2NDSXNJbWxrSWpvaWN5MWhaamswWlRZMlpEY3pOV00zTkdSaU4ySTFNams1TjJKa05qa3pPR0l3Tm1ReU9UazVNalF4TXpFeU0yUmpOekF6TjJFeU5XWTJaakEzWXpOak9UVmhJaXdpYm1GdFpTSTZJa1pwWTNScGIyNWhiQ0JCZEd4aGN5NXRaQ0lzSW5CeWIyUjFZM1JXWlhKemFXOXVJam9pTkM0eUlpd2ljSEp2ZG1sa1pYSWlPaUptYVdOMGFXOXVZV3dnZEdWemRDQnpiM1Z5WTJVaUxDSnlaWFpwYzJsdmJpSTZJbVpwWTNScGIyNWhiQzF5TVNJc0luTm9ZVEkxTmlJNkltTm1ZMll3TTJSaVpHVmhZakE0WWpVME5tUXdNMlV5WmpobFpqQTRNalptWm1Ga01qSXdOMll3WmpVeU1EUTFOVGt4WlRnMlpEWmlNemRqTjJFM01UVWlMQ0owWlhoMElqb2lRWFJzWVhNZ05DNHlPaUJGZUhCdmNuUWdZU0J6WVhabFpDQmtjbUZtZENCbWNtOXRJRVpwYkdVZ1BpQkZlSEJ2Y25RZ2QyaGxiaUIwYUdVZ1pISmhablFnYUdGeklHSmxaVzRnYzJGMlpXUXVYRzVjYmxWdWNtVjJhV1YzWldRZ2JtVnBaMmhpYjNJNklHTmhiR3dnWm1GclpTMXdjbWwyWVhSbFFHVjRZVzF3YkdVdWFXNTJZV3hwWkM0aUxDSjFjbXh6SWpwYlhYMWRmUT09Iiwic2lnbmF0dXJlIjoiVGZCRjFKN3YxTWc4R09rSXhIR1wvdmcyWk9GQjZBT2JiMTdZS0VWT3FBdzB5eTFacm9OTGg5SjZEWkNlYkd1MzBjeVZHWnJDT3EzR0ZjRFJOem96VkNRPT0ifQ==")!

    @MainActor static func runSync(_ check: @escaping (String, Bool) -> Void) {
        var finished = false
        let task = Task { @MainActor in
            do { try await run(check) }
            catch { check("fact evaluator actual fixture loop: " + String(describing: error), false) }
            finished = true
        }
        let deadline = Date.now + 15
        while !finished && Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
        if !finished { task.cancel() }
        check("fact evaluator bounded component loop completes", finished)
    }

    @MainActor private static func run(_ check: (String, Bool) -> Void) async throws {
        let catalog = try ReviewedAnswerCatalog.decode(fixtureData)
        let source = catalog.sources[0], fact = catalog.facts![0]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("facts-eval-" + UUID().uuidString)
        let group = root.appendingPathComponent("frozen")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try fixtureData.write(to: group.appendingPathComponent("catalog.json"))
        try Data(source.text.utf8).write(to: group.appendingPathComponent("source.md"))
        let questions = ["How do I export a saved draft in Atlas 4.2?", "What is the weather tomorrow?",
                         "How do I export my saved Atlas 4.2 draft?"]
        let cases = questions.enumerated().map { index, question in
            ["id": "synthetic-" + String(index), "question": question,
             "previous": index == 0 ? "Them: A saved draft is ready. Contact private.person@example.invalid." : "",
             "expected_unit": "DO_NOT_SEND_ORACLE", "expected_reply": "DO_NOT_SEND_ORACLE"]
        }
        let caseData = try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys])
        try caseData.write(to: group.appendingPathComponent("cases.json"))
        var manifest: [String: Any] = [
            "schema": 2, "knowledgeMode": "reviewedFacts", "buildCommit": String(repeating: "1", count: 40),
            "catalog": ["path": "catalog.json", "sha256": ReviewedAnswerCatalog.sha256(fixtureData)],
            "cases": ["path": "cases.json", "sha256": ReviewedAnswerCatalog.sha256(caseData)],
            "sources": [["sourceID": source.id, "path": "source.md", "sha256": source.sha256]],
            "units": [["id": fact.id, "digest": fact.contentDigest]],
            "modes": ["isolated", "rolling"], "resultPath": "result.jsonl"]
        let url = group.appendingPathComponent("manifest.json")
        func writeManifest() throws {
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url)
        }
        try writeManifest()
        do {
            _ = try ReviewedSelectorInput.prepare(manifestURL: url, allowedRoot: root)
            check("fact schema cannot enter whole-reply reader", false)
        } catch { check("fact schema cannot enter whole-reply reader", true) }
        let prepared = try ReviewedSelectorInput.prepareFacts(manifestURL: url, allowedRoot: root)
        check("fact input admits exact signed/source bytes", prepared.snapshot.facts.count == 1 &&
            prepared.snapshot.answers.isEmpty && prepared.catalogData == fixtureData)
        check("fact input preserves all questions and drops oracle annotations",
            prepared.cases.map(\.question) == questions &&
            !String(decoding: try JSONEncoder().encode(prepared.cases), as: UTF8.self).contains("DO_NOT_SEND_ORACLE"))
        manifest["schema"] = 1
        try writeManifest()
        do {
            _ = try ReviewedSelectorInput.prepareFacts(manifestURL: url, allowedRoot: root)
            check("fact reader refuses old schema", false)
        } catch { check("fact reader refuses old schema", true) }
        manifest["schema"] = 2
        manifest["units"] = [["id": fact.id, "digest": String(repeating: "0", count: 64)]]
        try writeManifest()
        do {
            _ = try ReviewedSelectorInput.prepareFacts(manifestURL: url, allowedRoot: root)
            check("fact reader refuses wrong fact digest", false)
        } catch { check("fact reader refuses wrong fact digest", true) }
        manifest["units"] = [["id": fact.id, "digest": fact.contentDigest]]
        try writeManifest()
        let kb = try KnowledgeBaseService.reviewedFactsDiagnostic(catalogData: fixtureData, expected: prepared.snapshot)
        check("diagnostic exact lexical index inventory admits", kb.diagnosticMatches(prepared.snapshot))
        let refs = await ReviewedFactsEval.retrieve(kb: kb, question: questions[0], transcript: "Them: " + questions[0])
        check("actual lexical search returns source including unreviewed neighbor", refs.contains { $0.text.contains("fake-private@example.invalid") })
        let kind = ProfileKind(id: UUID(), key: "suggestion", label: "Answer", colorHex: "#00897B",
            iconSystemName: "bubble.left", triggerDescription: "Answer.", isPinned: false, priority: 0)
        var request = AnalysisRequest(transcript: "Them: " + questions[0], currentQuestion: questions[0],
            knownInsightTitles: [], references: refs, instructions: "", callBrief: "", allowGeneralKnowledge: false,
            knownDocumentNames: [source.name], persona: "", counterpart: "client", kinds: [kind], gauges: [])
        request.reviewedCatalog = prepared.snapshot
        request.reviewedQuestionKey = questions[0]
        request = request.preparingReviewedFacts()
        let parsed = ClaudeAnalysisProvider.parseStrictAnswer(from: ReviewedTransportTests.envelope([
            "reply": "In Atlas 4.2, once the draft is saved, choose File > Export.", "evidence_ids": ["p0"]]), request: request).insights[0]
        check("fact provenance checker accepts app-resolved exact metadata", ReviewedFactsEval.citationsMatch(draft: parsed, count: 1, request: request))
        var altered = parsed; altered.evidenceFactCitations = []
        check("fact provenance checker rejects removed identities", !ReviewedFactsEval.citationsMatch(draft: altered, count: 1, request: request))
        altered = parsed; altered.evidenceReferenceIndices = [99]
        check("fact provenance checker rejects invalid passage positions", !ReviewedFactsEval.citationsMatch(draft: altered, count: 1, request: request))
        altered = parsed; altered.reply = "Choose File > Export."
        check("fact provenance checker rejects missing version boundary", !ReviewedFactsEval.citationsMatch(draft: altered, count: 1, request: request))
        var stale = request; stale.currentQuestion = "Another question?"
        check("fact provenance checker rejects wrong question context", !ReviewedFactsEval.citationsMatch(draft: parsed, count: 1, request: stale))
        check("fact provenance checker rejects multiple returned drafts", !ReviewedFactsEval.citationsMatch(draft: parsed, count: 2, request: request))
        await kb.addDocuments(at: [group.appendingPathComponent("source.md")])
        check("diagnostic cannot replace sources or download embeddings", kb.lastError != nil && kb.diagnosticMatches(prepared.snapshot))
        kb.setScope(.off, for: kb.documents[0])
        check("diagnostic inventory rejects source turned off", !kb.diagnosticMatches(prepared.snapshot))

        let defaults = UserDefaults.standard, prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = prior
        settings["copilotProvider"] = "claude"; settings["onDeviceOnly"] = false
        settings["redactCloud"] = true; settings["redactNames"] = false
        defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FactEvalMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FactEvalMockProtocol.bodies = []
        FactEvalMockProtocol.timeoutAttempts = 0
        var rows: [ReviewedFactsEval.Row] = [], factories = 0
        let journal = try ReviewedSelectorJournal(url: prepared.resultURL,
            header: ["type": "header", "diagnostic": "fictional-fact-execution"], expectedRows: 6)
        try await ReviewedFactsEval.execute(prepared: prepared, makeChannel: {
            FactEvalMockProtocol.behavior = factories; factories += 1
            let claude = ClaudeAnalysisProvider(session: session, keyProvider: { "synthetic-placeholder" })
            return ReviewedFactsEval.Channel(provider: SwitchingAnalysisProvider(claude: claude),
                usageCalls: { claude.usageTotals.calls })
        }, record: { try journal.append($0); rows.append($0) })
        let receipt = try journal.finish()
        check("fact execution complete private journal readback", receipt.rows == 6 && ReviewedSelectorJournal.verifies(receipt, at: prepared.resultURL))
        check("fact execution retains unsupported and failed cases in both modes", rows.count == 6 && factories == 6 &&
            rows.map(\.caseID) == ["synthetic-0", "synthetic-1", "synthetic-2", "synthetic-0", "synthetic-1", "synthetic-2"] &&
            rows.map(\.mode) == ["isolated", "isolated", "isolated", "rolling", "rolling", "rolling"])
        guard rows.count == 6 else { return }
        check("fact execution exact latest question preserved", rows.map(\.question) == questions + questions)
        check("fact execution fresh invocation per row", Set(rows.map(\.invocationID)).count == 6)
        check("fact execution real generation and review meter", rows[0].usageCalls == 2 && rows[0].citationConsistency && rows[0].insightCount == 1)
        check("fact execution resolves original reviewed bytes locally", rows[0].citations.first?.factDigest == fact.contentDigest && rows[0].evidence.first?.text == fact.evidence.quote)
        check("fact execution empty support sends no request and cannot pass", rows[1].usageCalls == 0 && !rows[1].citationConsistency)
        check("fact execution negative reviewer verdict cannot pass", rows[2].usageCalls == 2 && !rows[2].citationConsistency && rows[2].citations.isEmpty)
        check("fact execution supported case actually reaches failing transport", FactEvalMockProtocol.timeoutAttempts > 0 &&
            !rows[3].nominatedFacts.isEmpty && rows[3].requestStatus == "failed")
        check("fact execution transport failure cannot pass or borrow evidence", rows[3].usageCalls == 0 && !rows[3].citationConsistency && rows[3].citations.isEmpty)
        check("fact execution never scores citation shape as correctness", rows.allSatisfy { $0.semanticStatus == "unscored" && !$0.nativeAcceptance })
        let sent = FactEvalMockProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }.joined()
        let saved = String(decoding: try Data(contentsOf: prepared.resultURL), as: UTF8.self)
        check("fact execution neighbor stays out of payload and result", !sent.contains("fake-private@example.invalid") && !saved.contains("fake-private@example.invalid"))
        check("fact execution no oracle or local case IDs sent", !sent.contains("DO_NOT_SEND_ORACLE") && !sent.contains("synthetic-0") && !sent.contains("expected_reply"))
        check("fact execution redacts conversation email before cloud payload", !sent.contains("private.person@example.invalid"))
        check("fact execution generation includes reviewed claim and condition", sent.contains(fact.claim) && sent.contains(fact.conditions[0]))
    }
}

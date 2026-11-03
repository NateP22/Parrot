import Foundation
import Darwin
import Security

/// Generated-answer component measurement, distinct from whole-reply selection.
/// A valid citation is provenance, never a semantic or native PASS.
enum ReviewedFactsEval {
    enum Failure: Error, Equatable { case rejected, input, build, route, key, result }
    struct Evidence: Encodable, Equatable {
        let documentName: String
        let text: String
        init(_ reference: KBReference) { documentName = reference.documentName; text = reference.text }
    }
    struct RetrievedReceipt: Encodable {
        let documentName: String, sourceID: String, sourceSHA256: String, textSHA256: String
        let textUTF8Bytes: Int
    }
    struct Row: Encodable {
        let type = "row", semanticStatus = "unscored", nativeAcceptance = false
        let caseID: String, mode: String, invocationID: String, question: String, transcriptSHA256: String
        let requestStatus: String, selectedRouteAtStart: String
        let elapsedNanoseconds: UInt64
        let usageCalls: Int, insightCount: Int
        let reply: String?, detail: String?, source: String?
        let retrieved: [RetrievedReceipt], nominatedFacts: [ReviewedAnswerCatalog.FactCitation]
        let citations: [ReviewedAnswerCatalog.FactCitation], evidence: [Evidence]
        let citationConsistency: Bool
    }
    struct Channel {
        let provider: AnalysisProvider
        /// Read the already-created Claude meter, without resolving other keys.
        let usageCalls: () -> Int
    }
    private struct UnitReceipt: Encodable { let id: String; let digest: String }
    private struct Header: Encodable {
        let type = "header", diagnostic = "reviewed-facts-answer-component"
        let schema = 1, inputSchema = 2, nativeAcceptance = false, scored = false
        let semanticStatus = "unscored"
        let timing = "Actual KB search plus analyze; excludes import, audio, transcription and visible UI."
        let retrieval = "Actual KnowledgeBaseService.search with embeddings disabled: lexical fallback only, not normal hybrid/native proof."
        let admission = "Fixed-root signed decode, exact source text, ephemeral chunking and normal in-memory KB admission; not a normal UI import."
        let context = "Fixture lines, not ASR segments; isolated and rolling use ReviewedSelectorContext v2."
        let denominator = "Every input case in every mode is retained regardless of coverage or result; citations are not correctness."
        let buildCommit: String, configuredModel: String, selectedRouteAtStart: String
        let manifestSHA256: String, catalogSHA256: String, casesSHA256: String, snapshotRevision: String
        let modes: [String], expectedRows: Int, redactionEnabled: Bool
        let files: [ReviewedSelectorInput.FileReceipt], units: [UnitReceipt]
    }

    /// Same two retrieval passes as the engine, using fixture lines in place
    /// of ASR segments. No oracle, case identity or expected answer is consulted.
    @MainActor static func retrieve(kb: KnowledgeBaseService, question: String,
                                    transcript: String) async -> [KBReference] {
        var references = await kb.search(query: question, topK: 12, contextNeighbors: 1)
        let lines = transcript.split(separator: "\n").suffix(8).map { line -> String in
            let value = String(line)
            for prefix in ["Them: ", "Me: "] where value.hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count))
            }
            return value
        }
        let recent = await kb.search(query: lines.joined(separator: " "))
        for reference in recent where !references.contains(where: {
            $0.documentName == reference.documentName && $0.text.contains(reference.text)
        }) { references.append(reference) }
        return references
    }

    static func citationsMatch(draft: InsightDraft?, count: Int, request: AnalysisRequest) -> Bool {
        guard count == 1, let draft, let reply = draft.reply,
              ClaudeAnalysisProvider.isConciseSpokenReply(reply), draft.answerKey == request.currentQuestion,
              let context = request.reviewedFactContext, !context.isEmpty,
              request.reviewedCatalog?.mode == .reviewedFacts,
              request.reviewedCatalog?.revisionToken == context.revisionToken,
              context.matches(question: request.currentQuestion ?? "",
                  selectionQuestion: request.reviewedQuestionKey ?? request.currentQuestion ?? "",
                  references: request.references),
              let indices = draft.evidenceReferenceIndices, (1...3).contains(indices.count),
              Set(indices).count == indices.count,
              indices.allSatisfy({ context.citations.indices.contains($0) }),
              draft.evidenceFactCitations == indices.map({ context.citations[$0] }) else { return false }
        guard indices.allSatisfy({ index in
            context.citations[index].documentedProductVersion.map {
                ReviewedAnswerCatalog.containsDocumentedVersion($0, in: reply)
            } ?? true
        }) else { return false }
        let references = indices.map { context.references[$0] }
        guard draft.evidenceReferences?.map(Evidence.init) == references.map(Evidence.init) else { return false }
        var names: [String] = []
        for reference in references where !names.contains(reference.documentName) { names.append(reference.documentName) }
        return draft.source == names.joined(separator: "; ")
    }

    @MainActor static func execute(prepared: ReviewedSelectorInput.Prepared,
        makeChannel: () -> Channel, record: (Row) throws -> Void) async throws {
        guard prepared.snapshot.mode == .reviewedFacts, !prepared.snapshot.facts.isEmpty,
              (1...128).contains(prepared.cases.count), !prepared.modes.isEmpty,
              prepared.modes.count <= 2, Set(prepared.modes).count == prepared.modes.count,
              Set(prepared.modes).isSubset(of: Set(["isolated", "rolling"])) else { throw Failure.rejected }
        let kb = try KnowledgeBaseService.reviewedFactsDiagnostic(catalogData: prepared.catalogData, expected: prepared.snapshot)
        let kind = ProfileKind(id: UUID(), key: "suggestion", label: "Answer", colorHex: "#00897B",
            iconSystemName: "bubble.left", triggerDescription: "Answer the current question using reviewed facts.",
            isPinned: false, priority: 0)
        for mode in prepared.modes {
            guard let contextMode = ReviewedSelectorContext.Mode(rawValue: mode) else { throw Failure.rejected }
            var history = ""
            for item in prepared.cases {
                try Task.checkCancellation()
                guard kb.diagnosticMatches(prepared.snapshot) else { throw Failure.input }
                guard SwitchingAnalysisProvider.liveKind == .claude else { throw Failure.route }
                let window = ReviewedSelectorContext.window(mode: contextMode, history: history,
                    previous: item.previous, question: item.question)
                let invocation = UUID().uuidString
                let channel = makeChannel()
                let started = DispatchTime.now().uptimeNanoseconds
                let retrieved = await retrieve(kb: kb, question: item.question, transcript: window.transcript)
                var request = AnalysisRequest(transcript: window.transcript, currentQuestion: item.question,
                    knownInsightTitles: [], references: retrieved, instructions: "", callBrief: "",
                    allowGeneralKnowledge: false, knownDocumentNames: kb.documentsInPlay(for: nil),
                    persona: "", counterpart: "client", kinds: [kind], gauges: [])
                request.reviewedCatalog = kb.reviewedAnswerSnapshot(for: nil)
                request.reviewedQuestionKey = item.question
                request = request.preparingReviewedFacts()
                var result: AnalysisResult?, status = "returned", cancelled = false
                do {
                    try Task.checkCancellation()
                    guard SwitchingAnalysisProvider.liveKind == .claude else { throw Failure.route }
                    result = try await channel.provider.analyze(request)
                } catch is CancellationError { status = "cancelled"; cancelled = true }
                catch { status = "failed" }
                if Task.isCancelled { status = "cancelled"; cancelled = true }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                let draft = result?.insights.first
                let retrievedReceipts = try retrieved.map { reference -> RetrievedReceipt in
                    guard let source = prepared.snapshot.sources.first(where: { $0.name == reference.documentName })
                    else { throw Failure.input }
                    let bytes = Data(reference.text.utf8)
                    return RetrievedReceipt(documentName: source.name, sourceID: source.id,
                        sourceSHA256: source.sha256, textSHA256: ReviewedAnswerCatalog.sha256(bytes), textUTF8Bytes: bytes.count)
                }
                try record(Row(caseID: item.id, mode: mode, invocationID: invocation, question: item.question,
                    transcriptSHA256: ReviewedAnswerCatalog.sha256(Data(window.transcript.utf8)),
                    requestStatus: status, selectedRouteAtStart: CopilotProviderKind.claude.rawValue,
                    elapsedNanoseconds: elapsed, usageCalls: channel.usageCalls(), insightCount: result?.insights.count ?? 0,
                    reply: draft?.reply, detail: draft?.detail, source: draft?.source,
                    retrieved: retrievedReceipts, nominatedFacts: request.reviewedFactContext?.citations ?? [],
                    citations: draft?.evidenceFactCitations ?? [], evidence: (draft?.evidenceReferences ?? []).map(Evidence.init),
                    citationConsistency: citationsMatch(draft: draft, count: result?.insights.count ?? 0, request: request)))
                if cancelled { throw CancellationError() }
                history = window.nextHistory
            }
        }
    }

    static func run(manifestPath: String) {
        Task { @MainActor in
            do { try await session(manifestPath: manifestPath); exit(0) }
            catch {
                // No provider messages, credentials or corpus in terminal output.
                let message = error as? Failure == .key ? "own QA key unavailable" : "incomplete or rejected"
                fputs("facts-eval: " + message + "\n", stderr); exit(2)
            }
        }
        dispatchMain()
    }

    @MainActor private static func session(manifestPath: String) async throws {
        guard QASetupLaunch.isActive, Bundle.main.bundleIdentifier == QASetupLaunch.bundleID,
              Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as? String == QASetupLaunch.bundleID,
              Array(CommandLine.arguments.dropFirst()) == ["--qa-setup", "--reviewed-facts-eval", manifestPath]
        else { throw Failure.rejected }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw Failure.input }
        let base = support.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let prepared: ReviewedSelectorInput.Prepared
        do {
            prepared = try ReviewedSelectorInput.prepareFacts(manifestURL: URL(fileURLWithPath: manifestPath),
                allowedRoot: base.appendingPathComponent("Parrot/FactsEval"))
        } catch { throw Failure.input }
        guard ReviewedSelectorEval.matchesBuild(expected: prepared.expectedBuildCommit,
            actual: Bundle.main.object(forInfoDictionaryKey: "ParrotSourceCommit")) else { throw Failure.build }
        guard SwitchingAnalysisProvider.liveKind == .claude else { throw Failure.route }
        let header = Header(buildCommit: prepared.expectedBuildCommit, configuredModel: ClaudeAnalysisProvider.model,
            selectedRouteAtStart: SwitchingAnalysisProvider.liveKind.rawValue, manifestSHA256: prepared.manifestSHA256,
            catalogSHA256: prepared.catalogSHA256, casesSHA256: prepared.casesSHA256,
            snapshotRevision: prepared.snapshot.revisionToken, modes: prepared.modes,
            expectedRows: prepared.cases.count * prepared.modes.count, redactionEnabled: Redactor.isEnabled,
            files: prepared.files, units: prepared.snapshot.facts.map { UnitReceipt(id: $0.id, digest: $0.contentDigest) })
        let journal = try ReviewedSelectorJournal(url: prepared.resultURL, header: header, expectedRows: header.expectedRows)
        // Reuse only the existing own-QA item; never prompt, fall back to the
        // original service, read clipboard/env/argv, or log credential bytes.
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure.key }
        var interaction = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess, !interaction.boolValue else { throw Failure.key }
        guard let key = await APIKeyStore.loadInBackground(account: "claude-api-key", allowInteraction: false),
              !key.isEmpty else { throw Failure.key }
        try await execute(prepared: prepared, makeChannel: {
            let claude = ClaudeAnalysisProvider(keyProvider: { key })
            return Channel(provider: SwitchingAnalysisProvider(claude: claude), usageCalls: { claude.usageTotals.calls })
        }, record: { try journal.append($0) })
        let receipt = try journal.finish()
        guard ReviewedSelectorJournal.verifies(receipt, at: prepared.resultURL) else { throw Failure.result }
        struct Success: Encodable {
            let type = "facts-eval-completion", nativeAcceptance = false, scored = false
            let receipt: ReviewedSelectorJournal.Completion
        }
        print(String(decoding: try JSONEncoder().encode(Success(receipt: receipt)), as: UTF8.self))
    }
}

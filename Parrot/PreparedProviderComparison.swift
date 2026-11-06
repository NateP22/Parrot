import Foundation
import Darwin
import Security

/// Ordered developer comparison. No audio/UI, oracle, scoring or native pass.
enum PreparedProviderComparison {
    enum Failure: Error { case rejected, input, build, privacy, route, key, response, result }
    struct Row: Encodable {
        let type = "row"
        let ordinal: Int, caseID: String, variant: String
        let declaredOriginalPayloadSHA256: String, declaredLogicalBytes: Int
        let stableContextSHA256: String, expectedWireSHA256: String
        let measurement: PreparedProviderHTTP.Result
        let semanticStatus = "unscored", nativeAcceptance = false
    }
    struct Header: Encodable {
        let type = "header", diagnostic = "prepared-provider-comparison"
        let schema = 1, expectedRows = 15, nativeAcceptance = false, scored = false
        let timing = "Full buffered HTTP response; excludes audio, transcription and visible UI."
        let retryPolicy = "One application attempt per row; stop on first transport/metadata failure."
        let provenance = "Packet and wire bytes verified; repository/source/qualification hashes are declared upstream provenance."
        let buildCommit: String, configuredModel: String, createdAt: String
        let manifestSHA256: String, packetSHA256: String
        let declaredRepositoryCommit: String, declaredSourcePacketSHA256: String
        let declaredWireQualificationSHA256: String
    }

    /// Every result is durably recorded before the next send. A failed record,
    /// cancellation or first transport/metadata failure stops this enumeration.
    static func execute(prepared: PreparedProviderInput.Prepared,
                        canSend: () throws -> Void,
                        send: (PreparedProviderInput.Row, UUID) async -> PreparedProviderHTTP.Result,
                        record: (Row) throws -> Void) async throws {
        guard prepared.rows.count == 15 else { throw Failure.input }
        for (index, item) in prepared.rows.enumerated() {
            try Task.checkCancellation()
            guard item.ordinal == index + 1 else { throw Failure.input }
            try canSend()
            let invocation = UUID()
            let measured = await send(item, invocation)
            try record(Row(ordinal: item.ordinal, caseID: item.caseID, variant: item.variant,
                declaredOriginalPayloadSHA256: item.declaredOriginalPayloadSHA256,
                declaredLogicalBytes: item.declaredLogicalBytes,
                stableContextSHA256: item.stableContextSHA256,
                expectedWireSHA256: item.wireSHA256, measurement: measured))
            if measured.cancellationObserved || Task.isCancelled { throw CancellationError() }
            guard measured.invocationID == invocation,
                  measured.status == "response_unscored",
                  measured.expectedModel == ClaudeAnalysisProvider.model,
                  measured.actualWireSHA256 == item.wireSHA256,
                  measured.actualRequestBytes == item.wireData.count,
                  measured.appAttempts == 1 else { throw Failure.response }
        }
    }

    static func checkCloudRoute() throws {
        guard !CloudGate.forcesLocal else { throw Failure.privacy }
        guard SwitchingAnalysisProvider.liveKind == .claude else { throw Failure.route }
    }

    // MARK: App-only session (not constructed by the pure component tests)
    static func run(manifestPath: String) {
        Task { @MainActor in
            do { try await session(manifestPath: manifestPath); exit(0) }
            catch {
                // No Error description, request/response text, key or path on stdout.
                let message: String
                switch error as? Failure {
                case .input: message = "input rejected"
                case .build: message = "build mismatch"
                case .privacy: message = "cloud access disabled"
                case .route: message = "selected route is not Claude"
                case .key: message = "own QA key unavailable"
                case .response: message = "first response failed transport or metadata checks"
                case .result: message = "result not verified"
                default: message = "incomplete or rejected"
                }
                fputs("prepared-provider-comparison: " + message + "\n", stderr)
                exit(2)
            }
        }
        dispatchMain()
    }

    @MainActor private static func session(manifestPath: String) async throws {
        guard QASetupLaunch.isActive, Bundle.main.bundleIdentifier == QASetupLaunch.bundleID,
              AnswerTraceRecorder.isAllowed(bundleID: Bundle.main.bundleIdentifier,
                  flag: Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace")),
              Bundle.main.object(forInfoDictionaryKey: "ParrotKeychainService") as? String == QASetupLaunch.bundleID,
              !APIKeyStore.isSessionOnly,
              Array(CommandLine.arguments.dropFirst()) == ["--qa-setup", "--prepared-provider-comparison", manifestPath]
        else { throw Failure.rejected }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw Failure.input }
        let base = support.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let root = base.appendingPathComponent("Parrot SAT54 QA/PreparedProviderComparisons")
        let prepared: PreparedProviderInput.Prepared
        do {
            prepared = try PreparedProviderInput.prepare(manifestURL: URL(fileURLWithPath: manifestPath),
                allowedRoot: root, model: ClaudeAnalysisProvider.model,
                expectedPacketSHA256: "3d880dee0a4ec15bce177bf49c2bf162bd67cbd40de996bc68c7ed3af2ccb008")
        } catch { throw Failure.input }
        guard prepared.declaredRepositoryCommit == "f68adc934b856384b55ee9f8b1bfa0b92d8462a3",
              prepared.declaredSourcePacketSHA256 == "9ddaee44d50e4f8ccb1c007f2ef2b2ef6c59697c1d55d6e83ff0b459a4e5971c",
              prepared.declaredWireQualificationSHA256 == "b0a1249685fe3dd9d21942cd160a7ad05ff8afdee4a5b30393e4534f1bb36ec2"
        else { throw Failure.input }
        guard Bundle.main.object(forInfoDictionaryKey: "ParrotSourceCommit") as? String == prepared.buildCommit
        else { throw Failure.build }
        try Task.checkCancellation()
        try checkCloudRoute()
        let header = Header(buildCommit: prepared.buildCommit, configuredModel: ClaudeAnalysisProvider.model,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            manifestSHA256: prepared.manifestSHA256, packetSHA256: prepared.packetSHA256,
            declaredRepositoryCommit: prepared.declaredRepositoryCommit,
            declaredSourcePacketSHA256: prepared.declaredSourcePacketSHA256,
            declaredWireQualificationSHA256: prepared.declaredWireQualificationSHA256)
        let journal: ReviewedSelectorJournal
        do { journal = try ReviewedSelectorJournal(url: prepared.resultURL, header: header, expectedRows: 15) }
        catch { throw Failure.result }
        // Own-QA read only, noninteractive. No argv/env/clipboard/legacy service.
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure.key }
        var interaction = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess, !interaction.boolValue
        else { throw Failure.key }
        guard let key = await APIKeyStore.loadInBackground(account: "claude-api-key", allowInteraction: false),
              !key.isEmpty else { throw Failure.key }
        try Task.checkCancellation()
        try checkCloudRoute() // Recheck preferences after the awaited key load.
        let http = PreparedProviderHTTP.session()
        defer { http.invalidateAndCancel() }
        let provider = ClaudeAnalysisProvider(session: http, keyProvider: { key })
        try await execute(prepared: prepared, canSend: checkCloudRoute, send: { item, invocation in
            await PreparedProviderHTTP.measure(invocationID: invocation, model: ClaudeAnalysisProvider.model,
                expectedWireSHA256: item.wireSHA256, expectedBytes: item.wireData.count) { observer in
                try await provider.sendPreparedComparison(body: item.body, observingHTTP: observer)
            }
        }, record: { try journal.append($0) })
        let receipt = try journal.finish()
        guard ReviewedSelectorJournal.verifies(receipt, at: prepared.resultURL) else { throw Failure.result }
        struct Success: Encodable {
            let type = "prepared-provider-comparison-completion", nativeAcceptance = false, scored = false
            let receipt: ReviewedSelectorJournal.Completion
        }
        print(String(decoding: try JSONEncoder().encode(Success(receipt: receipt)), as: UTF8.self))
    }
}

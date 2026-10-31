import Foundation
import Darwin

/// Exact-QA, no-audio production-selector diagnostic; never scores native answers.
enum ReviewedSelectorEval {
    enum Failure: Error { case unavailable, rejected, input, build, route, key, result }
    struct Evidence: Encodable, Equatable {
        let documentName:String
        let text:String
    }
    struct Row: Encodable {
        let type="row"
        let caseID:String,mode:String,invocationID:String,question:String,transcriptSHA256:String
        let observation:ReviewedSelectorObservation
        let requestStatus:String,selectedRouteAtStart:String
        let elapsedNanoseconds:UInt64
        let usageCalls:Int,insightCount:Int
        let reply:String?,source:String?,selectedUnitDigest:String?
        let evidence:[Evidence]
        let outputMatchesObservedUnit:Bool
        let semanticStatus="unscored"
        let nativeAcceptance=false
    }
    private struct UnitReceipt: Encodable { let id:String; let digest:String }
    private struct Header: Encodable {
        let type="header",diagnostic="reviewed-selector-component"
        let schema=1,nativeAcceptance=false,scored=false
        let timing="Component analyze call only; excludes audio, transcription and visible UI."
        let admission="Normal signed decode plus source-byte admission in memory; not a normal KB import."
        let contextVersion=2
        let isolated="Question only; excludes fixture previous and accumulated history."
        let rolling="Prior fixture questions plus explicit previous; overlapping prior context merged, current repetitions preserved."
        let buildCommit:String,configuredModel:String,selectedRouteAtStart:String
        let manifestSHA256:String,catalogSHA256:String,casesSHA256:String,snapshotRevision:String
        let modes:[String]
        let expectedRows:Int
        let redactionEnabled:Bool
        let files:[ReviewedSelectorInput.FileReceipt]
        let units:[UnitReceipt]
    }
    static func matchesBuild(expected:String,actual:Any?) -> Bool {
        guard expected.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil,
              let actual=actual as? String else { return false }
        return actual==expected
    }

    static func execute(prepared:ReviewedSelectorInput.Prepared,
                        makeProvider:(ReviewedSelectorObservationCapture)->AnalysisProvider,
                        record:(Row)throws->Void) async throws {
        guard (1...128).contains(prepared.cases.count),!prepared.modes.isEmpty,
              prepared.modes.count<=2,Set(prepared.modes).count==prepared.modes.count,
              Set(prepared.modes).isSubset(of:Set(["isolated","rolling"])) else { throw Failure.rejected }
        let names=prepared.snapshot.sources.map(\.name)
        for mode in prepared.modes {
            guard let contextMode=ReviewedSelectorContext.Mode(rawValue:mode) else { throw Failure.rejected }
            var history=""
            for item in prepared.cases {
                try Task.checkCancellation()
                let window=ReviewedSelectorContext.window(mode:contextMode,history:history,previous:item.previous,question:item.question)
                let transcript=window.transcript
                var request=AnalysisRequest(transcript:transcript,currentQuestion:item.question,knownInsightTitles:[],
                    references:[],instructions:"",callBrief:"",allowGeneralKnowledge:false,
                    knownDocumentNames:names,persona:"",counterpart:"client",kinds:[],gauges:[])
                request.reviewedCatalog=prepared.snapshot
                request.reviewedQuestionKey=item.question
                let capture=ReviewedSelectorObservationCapture()
                let provider=makeProvider(capture)
                let route=SwitchingAnalysisProvider.liveKind.rawValue
                let started=DispatchTime.now().uptimeNanoseconds
                var result:AnalysisResult?,status="returned",cancelled=false
                do { result=try await provider.analyze(request) }
                catch is CancellationError { status="cancelled";cancelled=true }
                catch { status="failed" }
                if Task.isCancelled { status="cancelled";cancelled=true }
                let ended=DispatchTime.now().uptimeNanoseconds
                guard ended>=started else { throw Failure.unavailable }
                let observed=capture.observation ?? ReviewedSelectorObservation(kind:.noResponse,unitID:nil)
                let draft=result?.insights.first
                let evidence=(draft?.evidenceReferences ?? []).map{Evidence(documentName:$0.documentName,text:$0.text)}
                let selected=observed.kind == .answer ? prepared.snapshot.answers.first{$0.id==observed.unitID} : nil
                var matches=false
                if let selected {
                    let refs=prepared.snapshot.references(for:selected.id)
                    let expected=refs.map{Evidence(documentName:$0.documentName,text:$0.text)}
                    var sources:[String]=[]
                    for ref in refs where !sources.contains(ref.documentName) { sources.append(ref.documentName) }
                    matches=result?.insights.count==1 && draft?.reply==selected.reply &&
                        draft?.source==sources.joined(separator:"; ") && evidence==expected &&
                        !expected.isEmpty && draft?.answerKey==item.question
                }
                try record(Row(caseID:item.id,mode:mode,invocationID:capture.invocationID.uuidString,
                    question:item.question,transcriptSHA256:ReviewedAnswerCatalog.sha256(Data(transcript.utf8)),
                    observation:observed,requestStatus:status,selectedRouteAtStart:route,
                    elapsedNanoseconds:ended-started,usageCalls:provider.usageTotals.calls,
                    insightCount:result?.insights.count ?? 0,reply:draft?.reply,source:draft?.source,
                    selectedUnitDigest:matches ? selected?.contentDigest : nil,evidence:evidence,
                    outputMatchesObservedUnit:matches))
                if cancelled { throw CancellationError() }
                history=window.nextHistory
            }
        }
    }

    /// Only ParrotMain's exact admitted command reaches here; no normal app,
    /// profile/KB/store, capture service or local model is constructed.
    static func run(manifestPath:String) {
        Task { @MainActor in
            do {
                try await session(manifestPath:manifestPath)
                exit(0)
            } catch {
                let message:String
                switch error as? Failure {
                case .input: message="input rejected"
                case .build: message="build mismatch"
                case .route: message="selected route is not Claude"
                case .key: message="own QA key unavailable"
                case .result: message="result not verified"
                default: message="incomplete or rejected"
                }
                fputs("selector-eval: "+message+"\n",stderr)
                exit(2)
            }
        }
        dispatchMain()
    }

    @MainActor private static func session(manifestPath:String) async throws {
        guard QASetupLaunch.isActive,Bundle.main.bundleIdentifier==QASetupLaunch.bundleID,
              Bundle.main.object(forInfoDictionaryKey:"ParrotKeychainService") as? String==QASetupLaunch.bundleID,
              Array(CommandLine.arguments.dropFirst())==["--qa-setup","--reviewed-selector-eval",manifestPath]
        else { throw Failure.rejected }
        guard let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
        else { throw Failure.input }
        // Canonicalize only the trusted Foundation base. Input.prepare rejects
        // redirects within the app-owned Parrot/SelectorEval descendants.
        let base=support.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let root=base.appendingPathComponent("Parrot/SelectorEval")
        let prepared:ReviewedSelectorInput.Prepared
        do { prepared=try ReviewedSelectorInput.prepare(manifestURL:URL(fileURLWithPath:manifestPath),allowedRoot:root) }
        catch { throw Failure.input }
        guard matchesBuild(expected:prepared.expectedBuildCommit,
            actual:Bundle.main.object(forInfoDictionaryKey:"ParrotSourceCommit")) else { throw Failure.build }
        guard SwitchingAnalysisProvider.liveKind == .claude else { throw Failure.route }
        let header=Header(buildCommit:prepared.expectedBuildCommit,configuredModel:ClaudeAnalysisProvider.model,
            selectedRouteAtStart:SwitchingAnalysisProvider.liveKind.rawValue,
            manifestSHA256:prepared.manifestSHA256,catalogSHA256:prepared.catalogSHA256,
            casesSHA256:prepared.casesSHA256,snapshotRevision:prepared.snapshot.revisionToken,
            modes:prepared.modes,expectedRows:prepared.cases.count*prepared.modes.count,
            redactionEnabled:Redactor.isEnabled,files:prepared.files,
            units:prepared.snapshot.answers.map{UnitReceipt(id:$0.id,digest:$0.contentDigest)})
        let journal:ReviewedSelectorJournal
        do { journal=try ReviewedSelectorJournal(url:prepared.resultURL,header:header,expectedRows:header.expectedRows) }
        catch { throw Failure.result }
        // Existing own-QA store only; no argv/env/clipboard/legacy retrieval.
        guard let key=await APIKeyStore.loadInBackground(),!key.isEmpty else { throw Failure.key }
        try await execute(prepared:prepared,makeProvider:{ capture in
            let invocation=capture.invocationID
            let claude=ClaudeAnalysisProvider(keyProvider:{key},reviewedResponseObserver:{
                capture.record($0,invocationID:invocation)
            })
            return SwitchingAnalysisProvider(claude:claude)
        },record:{try journal.append($0)})
        let receipt=try journal.finish()
        guard ReviewedSelectorJournal.verifies(receipt,at:prepared.resultURL) else { throw Failure.result }
        struct Success:Encodable {
            let type="selector-eval-completion",nativeAcceptance=false,scored=false
            let receipt:ReviewedSelectorJournal.Completion
        }
        // Bounded status only. Questions/replies/evidence remain in the0600 file.
        print(String(decoding:try JSONEncoder().encode(Success(receipt:receipt)),as:UTF8.self))
    }
}

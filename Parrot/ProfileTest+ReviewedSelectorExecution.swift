import Foundation

enum ReviewedSelectorExecutionChecks {
    @MainActor static func runSync(_ check:@escaping(String,Bool)->Void) {
        let commit=String(repeating:"1",count:40)
        check("selector execution exact runtime build match",ReviewedSelectorEval.matchesBuild(expected:commit,actual:commit))
        check("selector execution rejects missing runtime build",!ReviewedSelectorEval.matchesBuild(expected:commit,actual:nil))
        check("selector execution rejects different runtime build",!ReviewedSelectorEval.matchesBuild(expected:commit,actual:String(repeating:"2",count:40)))
        check("selector execution rejects malformed runtime build",!ReviewedSelectorEval.matchesBuild(expected:commit,actual:commit+"extra"))
        check("selector execution rejects nonstring runtime build",!ReviewedSelectorEval.matchesBuild(expected:commit,actual:1))
        var finished=false
        let task=Task { @MainActor in
            do { try await run(check) }
            catch { check("selector execution completes actual provider loop",false) }
            finished=true
        }
        let deadline=Date.now+10
        while !finished && Date.now<deadline { RunLoop.main.run(until:.now+0.01) }
        if !finished { task.cancel() }
        check("selector execution terminates within bounded fixture time",finished)
    }

    @MainActor private static func run(_ check:(String,Bool)->Void) async throws {
        let catalog=try ReviewedAnswerCatalog.decode(ReviewedAnswerTests.fixtureData)
        let source=catalog.sources[0],answer=catalog.answers[0]
        let cases=[ReviewedSelectorInput.ExecutionCase(id:"fixture-case-a",question:"How do I export a saved draft?",previous:"Them: The draft is already saved."),
                   ReviewedSelectorInput.ExecutionCase(id:"fixture-case-b",question:"How do I export a saved café draft?",previous:"How do I export a saved draft?")]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("selector-execution-"+UUID().uuidString)
        let group=root.appendingPathComponent("frozen")
        try FileManager.default.createDirectory(at:group,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let sourceData=Data(source.text.utf8)
        try ReviewedAnswerTests.fixtureData.write(to:group.appendingPathComponent("catalog.json"))
        try sourceData.write(to:group.appendingPathComponent("source.md"))
        let caseData=try JSONSerialization.data(withJSONObject:cases.map { item in
            ["id":item.id,"question":item.question,"previous":item.previous,
             "expected_unit":"DO_NOT_SEND_ORACLE","expectation":"DO_NOT_SEND_ORACLE","reason":"DO_NOT_SEND_ORACLE"]
        },options:[.sortedKeys])
        try caseData.write(to:group.appendingPathComponent("cases.json"))
        let manifest:[String:Any]=[
            "schema":1,"buildCommit":String(repeating:"1",count:40),
            "catalog":["path":"catalog.json","sha256":ReviewedAnswerCatalog.sha256(ReviewedAnswerTests.fixtureData)],
            "cases":["path":"cases.json","sha256":ReviewedAnswerCatalog.sha256(caseData)],
            "sources":[["sourceID":source.id,"path":"source.md","sha256":source.sha256]],
            "units":[["id":answer.id,"digest":answer.contentDigest]],
            "modes":["isolated","rolling"],"resultPath":"result.jsonl"]
        let manifestURL=group.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:manifestURL)
        let prepared=try ReviewedSelectorInput.prepare(manifestURL:manifestURL,allowedRoot:root)
        check("selector execution prepares exact signed source/case files",prepared.files.count==4 && prepared.snapshot.answers.count==1)
        let journal=try ReviewedSelectorJournal(url:prepared.resultURL,header:["type":"header","diagnostic":"fictional-execution"],expectedRows:4)
        let defaults=UserDefaults.standard,prior=UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
        var settings=prior
        settings["copilotProvider"]="claude";settings["onDeviceOnly"]=false
        settings["redactCloud"]=false;settings["redactNames"]=false
        defaults.setVolatileDomain(settings,forName:UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior,forName:UserDefaults.argumentDomain) }
        let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ReviewedMockProtocol.self]
        let session=URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        ReviewedMockProtocol.requests=[];ReviewedMockProtocol.bodies=[]
        var factories=0,rows:[ReviewedSelectorEval.Row]=[]
        try await ReviewedSelectorEval.execute(prepared:prepared,makeProvider:{ capture in
            let invocation=capture.invocationID
            let index=factories;factories += 1
            ReviewedMockProtocol.code=200;ReviewedMockProtocol.failure=nil
            switch index {
            case 0: ReviewedMockProtocol.reply=ReviewedTransportTests.envelope(["mode":"answer","unit_id":answer.id])
            case 1: ReviewedMockProtocol.reply=ReviewedTransportTests.envelope(["mode":"uncertain","unit_id":""])
            case 2: ReviewedMockProtocol.reply=ReviewedTransportTests.envelope(["mode":"answer","unit_id":"invented-unit"])
            default:
                ReviewedMockProtocol.reply=ReviewedTransportTests.envelope(["mode":"answer","unit_id":answer.id])
                ReviewedMockProtocol.failure=URLError(.timedOut)
            }
            let claude=ClaudeAnalysisProvider(session:session,keyProvider:{"synthetic-placeholder"},reviewedResponseObserver:{
                capture.record($0,invocationID:invocation)
            })
            return SwitchingAnalysisProvider(claude:claude,localCompatible:OpenAICompatibleProvider(session:session,kindSource:{.ollama}))
        },record:{try journal.append($0);rows.append($0)})
        let receipt=try journal.finish()
        check("selector execution actual prepared provider loop journal verifies",receipt.rows==4 && ReviewedSelectorJournal.verifies(receipt,at:prepared.resultURL))
        check("selector execution one sequential row per case and mode",rows.count==4 && factories==4 &&
              rows.map(\.caseID)==["fixture-case-a","fixture-case-b","fixture-case-a","fixture-case-b"] &&
              rows.map(\.mode)==["isolated","isolated","rolling","rolling"])
        guard rows.count==4 else { return }
        check("selector execution fresh invocation identity per call",Set(rows.map(\.invocationID)).count==4)
        check("selector execution preserves all exact question text",rows.map(\.question)==[cases[0].question,cases[1].question,cases[0].question,cases[1].question])
        check("selector execution observes actual known/uncertain/invalid/timeout",rows.map{$0.observation.kind}==[.answer,.uncertain,.invalid,.noResponse])
        check("selector execution binds original output separately from selection",
              rows[0].outputMatchesObservedUnit && rows[0].selectedUnitDigest==answer.contentDigest &&
              rows[0].reply==answer.reply && rows[0].source==source.name &&
              rows[0].evidence.first?.text==answer.evidence[0].quote)
        check("selector execution fallback never borrows prior selected unit",
              rows.dropFirst().allSatisfy{!$0.outputMatchesObservedUnit && $0.selectedUnitDigest==nil &&
                  $0.reply==ClaudeAnalysisProvider.reviewedUncertaintyReply && $0.source==nil && $0.evidence.isEmpty})
        check("selector execution every row remains unscored",rows.allSatisfy{$0.semanticStatus=="unscored" && !$0.nativeAcceptance})
        check("selector execution uses actual production mock transport",ReviewedMockProtocol.requests.count==4)
        let payloads=try ReviewedMockProtocol.bodies.map { data -> [String:Any] in
            let body=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let messages=body["messages"] as! [[String:Any]]
            return try JSONSerialization.jsonObject(with:Data((messages[0]["content"] as! String).utf8)) as! [String:Any]
        }
        check("selector execution actual latest_question never becomes rolling history",
              payloads.compactMap{$0["latest_question"] as? String}==[cases[0].question,cases[1].question,cases[0].question,cases[1].question])
        let conversations=payloads.compactMap{$0["recent_conversation"] as? String}
        check("selector execution isolated starts fresh and rolling carries preceding question",
              conversations.count==4 && !conversations[1].contains(cases[0].question) &&
              conversations[3].components(separatedBy:cases[0].question).count==2)
        let sent=ReviewedMockProtocol.bodies.map{String(decoding:$0,as:UTF8.self)}.joined()
        check("selector execution never serializes local case identities or score keys",
              !sent.contains("fixture-case-") && !sent.contains("DO_NOT_SEND_ORACLE") && !sent.contains("expected_unit") && !sent.contains("review_required") && !sent.contains("semanticStatus"))
    }
}

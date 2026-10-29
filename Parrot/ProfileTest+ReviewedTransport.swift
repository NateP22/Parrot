
import Foundation
final class ReviewedMockProtocol: URLProtocol {
    static var reply=Data()
    static var code=200
    static var failure:URLError?
    static var requests:[URLRequest]=[]
    static var bodies:[Data]=[]
    override class func canInit(with request: URLRequest)->Bool { true }
    override class func canonicalRequest(for request: URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.requests.append(request)
        if let data=request.httpBody { Self.bodies.append(data) }
        else if let stream=request.httpBodyStream {
            stream.open();defer { stream.close() }
            var result=Data(),buffer=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};result.append(buffer,count:n) }
            Self.bodies.append(result)
        } else { Self.bodies.append(Data()) }
        if let failure=Self.failure {client?.urlProtocol(self,didFailWithError:failure);return}
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.code,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum ReviewedTransportTests {
    static var count=0,failed=0
    @MainActor
    static func runSync(_ check:(String,Bool)->Void) {
        var finished=false,error:String?
        let task=Task {
            do {try await run()} catch let caught {error=caught.localizedDescription}
            finished=true
        }
        let deadline=Date.now+10
        while !finished && Date.now<deadline {RunLoop.main.run(until:.now+0.01)}
        if !finished {task.cancel()}
        check("reviewed transport completed",finished && error==nil)
        check("reviewed transport assertions",finished && failed==0 && count>=55)
    }
    static func check(_ name:String,_ okay:Bool) {
        count += 1
        if !okay {failed += 1;print("FAIL "+name)}
    }
    static func envelope(_ object:[String:Any],stop:String="end_turn")->Data {
        let text=String(decoding:try! JSONSerialization.data(withJSONObject:object),as:UTF8.self)
        return try! JSONSerialization.data(withJSONObject:["content":[["type":"text","text":text]],"stop_reason":stop,"usage":["input_tokens":10,"output_tokens":5]])
    }
    static func run() async throws {
        count=0;failed=0
        let catalog=try ReviewedAnswerCatalog.decode(ReviewedAnswerTests.fixtureData)
        let source=catalog.sources[0], answer=catalog.answers[0]
        let doc=KBDocument(name:source.name,chunkCount:1,addedAt:Date(),contentSHA256:source.sha256)
        let snapshot=catalog.admitted(documents:[doc],folders:[],profileID:nil)
        check("fixture admitted",snapshot.answers.count==1)
        var request=AnalysisRequest(transcript:"Them: How do I export a saved café draft? Contact private.person@example.invalid.",currentQuestion:"How do I export a saved café draft?",knownInsightTitles:[],references:[],instructions:"",callBrief:"",allowGeneralKnowledge:false,knownDocumentNames:[source.name],persona:"",counterpart:"client",kinds:[],gauges:[])
        request.reviewedCatalog=snapshot
        request.reviewedQuestionKey=request.currentQuestion
        let cfg=URLSessionConfiguration.ephemeral
        cfg.protocolClasses=[ReviewedMockProtocol.self]
        let session=URLSession(configuration:cfg)
        defer { session.invalidateAndCancel() }
        let provider=ClaudeAnalysisProvider(session:session,keyProvider:{"synthetic-placeholder"})
        func run(_ object:[String:Any],stop:String="end_turn",code:Int=200,error:URLError?=nil,nilRequest req:AnalysisRequest?=nil) async throws->InsightDraft {
            ReviewedMockProtocol.reply=envelope(object,stop:stop)
            ReviewedMockProtocol.code=code;ReviewedMockProtocol.failure=error
            ReviewedMockProtocol.requests=[];ReviewedMockProtocol.bodies=[]
            let r=try await provider.analyze(req ?? request)
            check("strict single result",r.insights.count==1 && r.coach==nil && r.read==nil && r.resolved.isEmpty && r.sentiment.isEmpty)
            return r.insights[0]
        }
        let selected=["mode":"answer","unit_id":answer.id]
        let good=try await run(selected)
        check("whole wording unchanged",good.reply==answer.reply)
        check("original evidence unchanged",good.evidenceQuote==answer.evidence[0].quote)
        check("original source resolved",good.source==source.name && good.evidenceReferences?.first?.text==answer.evidence[0].quote)
        check("question identity preserved",good.answerKey==request.currentQuestion)
        check("single selector request",ReviewedMockProtocol.requests.count==1)
        let sent=ReviewedMockProtocol.requests[0]
        let body=try JSONSerialization.jsonObject(with:ReviewedMockProtocol.bodies[0]) as! [String:Any]
        check("fixed Haiku model",body["model"] as? String=="claude-haiku-5-5")
        check("small output budget",body["max_tokens"] as? Int==128)
        check("thinking disabled",(body["thinking"] as? [String:String])?["type"]=="disabled")
        check("two second network timeout",sent.timeoutInterval==2)
        let output=body["output_config"] as? [String:Any]
        let format=output?["format"] as? [String:Any]
        let schema=format?["schema"] as? [String:Any]
        let props=schema?["properties"] as? [String:Any]
        check("stable unconstrained id grammar",(props?["unit_id"] as? [String:Any])?["enum"]==nil)
        check("usage metered",provider.usageTotals.calls==1)
        for (name,object,stop) in [
            ("unknown id",["mode":"answer","unit_id":"a-invented"],"end_turn"),
            ("uncertain mode",["mode":"uncertain","unit_id":answer.id],"end_turn"),
            ("unexpected mode",["mode":"sure","unit_id":answer.id],"end_turn"),
            ("extra prose",["mode":"answer","unit_id":answer.id,"reply":"An invented edit."],"end_turn"),
            ("truncated output",selected,"max_tokens"),
            ("empty id",["mode":"answer","unit_id":""],"end_turn")] {
            let d=try await run(object,stop:stop)
            check(name+" neutral",d.reply==ClaudeAnalysisProvider.reviewedUncertaintyReply && d.source==nil && d.evidenceQuote==nil)
        }
        let rate=try await run(selected,code:429)
        check("no retry on 429",ReviewedMockProtocol.requests.count==1 && rate.source==nil)
        let unavailable=try await run(selected,code:503)
        check("no retry on 503",ReviewedMockProtocol.requests.count==1 && unavailable.source==nil)
        let timeout=try await run(selected,error:URLError(.timedOut))
        check("timeout neutral",timeout.reply==ClaudeAnalysisProvider.reviewedUncertaintyReply)
        var wrongNames=AnalysisRequest(transcript:request.transcript,currentQuestion:request.currentQuestion,knownInsightTitles:[],references:[],instructions:"",callBrief:"",allowGeneralKnowledge:false,knownDocumentNames:["other.md"],persona:"",counterpart:"",kinds:[],gauges:[])
        wrongNames.reviewedCatalog=snapshot
        let outOfScope=try await run(selected,nilRequest:wrongNames)
        check("missing document no network",ReviewedMockProtocol.requests.isEmpty && outOfScope.source==nil)
        var unavailableRequest=request
        unavailableRequest.reviewedCatalog = .unavailable("invalid signed file")
        let noLibrary=try await run(selected,nilRequest:unavailableRequest)
        check("unavailable library no network",ReviewedMockProtocol.requests.isEmpty && noLibrary.source==nil)
        var older=request
        older.currentQuestion="How do I export a saved draft in 0.9.0?"
        older.reviewedQuestionKey=older.currentQuestion
        let wrongVersion=try await run(selected,nilRequest:older)
        check("different version no network",ReviewedMockProtocol.requests.isEmpty && wrongVersion.source==nil)
        var redactor=Redactor(hideNames:false)
        var privateRequest=request
        privateRequest.currentQuestion="How do I export a saved café draft for private.person@example.invalid?"
        privateRequest.reviewedQuestionKey=privateRequest.currentQuestion
        let privateProjection=redactor.redact(privateRequest)
        check("local identity remains original",privateProjection.reviewedQuestionKey==privateRequest.currentQuestion)
        check("local catalog retained",privateProjection.reviewedCatalog?.revisionToken==snapshot.revisionToken)
        check("question cloud redacted",privateProjection.currentQuestion?.contains("private.person@example.invalid")==false)
        let privateGood=try await run(selected,nilRequest:privateProjection)
        let privateBody=String(decoding:ReviewedMockProtocol.bodies[0],as:UTF8.self)
        check("HTTP excludes private question/transcript",!privateBody.contains("private.person@example.invalid") && privateBody.contains("[EMAIL_1]"))
        check("projection has no original catalog blob",!privateBody.contains("source_input") && !privateBody.contains("startUTF8") && !privateBody.contains("sha256"))
        check("reply remains original approved",privateGood.reply==answer.reply && privateGood.evidenceQuote==answer.evidence[0].quote)
        check("private question identity restored locally",privateGood.answerKey==privateRequest.currentQuestion)
        let malformed=Data("{broken".utf8)
        let bad=ClaudeAnalysisProvider.reviewedAnswerDraft(from:malformed,request:request,catalog:snapshot,candidates:[answer])
        check("malformed response neutral",bad.source==nil && bad.reply==ClaudeAnalysisProvider.reviewedUncertaintyReply)
        var alienJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(answer)) as! [String:Any]
        alienJSON["reply"]="Changed outside the reviewed catalog."
        let alien=try JSONDecoder().decode(ReviewedAnswerCatalog.Answer.self,from:JSONSerialization.data(withJSONObject:alienJSON))
        let altered=ClaudeAnalysisProvider.reviewedAnswerDraft(from:envelope(selected),request:request,catalog:snapshot,candidates:[alien])
        check("modified unit rejected",altered.source==nil)
        check("no exact original quote serialized",!privateBody.contains(answer.evidence[0].quote))
        let defaults=UserDefaults.standard
        let prior=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        var settings=prior
        settings["copilotProvider"]="claude";settings["onDeviceOnly"]=false
        settings["redactCloud"]=true;settings["redactNames"]=false
        defaults.setVolatileDomain(settings,forName:UserDefaults.argumentDomain)
        defer {defaults.setVolatileDomain(prior,forName:UserDefaults.argumentDomain)}
        let isolatedLocal=OpenAICompatibleProvider(session:session,kindSource:{.ollama})
        let switching=SwitchingAnalysisProvider(claude:provider,localCompatible:isolatedLocal)
        ReviewedMockProtocol.reply=envelope(selected);ReviewedMockProtocol.code=200;ReviewedMockProtocol.failure=nil
        ReviewedMockProtocol.requests=[];ReviewedMockProtocol.bodies=[]
        let factory=try await switching.analyze(privateRequest)
        check("factory uses tested cloud provider",ReviewedMockProtocol.requests.count==1)
        let factoryBody=ReviewedMockProtocol.bodies.first.map {String(decoding:$0,as:UTF8.self)} ?? ""
        check("factory redacts cloud question",!factoryBody.contains("private.person@example.invalid") && factoryBody.contains("[EMAIL_1]"))
        check("factory preserves approved reply/quote/key",factory.insights.first?.reply==answer.reply && factory.insights.first?.evidenceQuote==answer.evidence[0].quote && factory.insights.first?.answerKey==privateRequest.currentQuestion)
        var localRequest=privateRequest;localRequest.forceLocal=true
        ReviewedMockProtocol.requests=[]
        let localResult=try await switching.analyze(localRequest)
        check("forced local never sends reviewed content",ReviewedMockProtocol.requests.isEmpty && localResult.insights.first?.source==nil)
        let scopedResult=try await CloudGate.$scopeLocal.withValue(true) {try await switching.analyze(privateRequest)}
        check("task scoped privacy never sends reviewed content",ReviewedMockProtocol.requests.isEmpty && scopedResult.insights.first?.source==nil)
        settings["onDeviceOnly"]=true
        defaults.setVolatileDomain(settings,forName:UserDefaults.argumentDomain)
        let globalResult=try await switching.analyze(privateRequest)
        check("global privacy never sends reviewed content",ReviewedMockProtocol.requests.isEmpty && globalResult.insights.first?.source==nil)
        let customResult=try await OpenAICompatibleProvider(session:session,kindSource:{.custom}).analyze(request)
        check("unsupported selector cannot use free prose",ReviewedMockProtocol.requests.isEmpty && customResult.insights.first?.source==nil && customResult.insights.first?.reply==ClaudeAnalysisProvider.reviewedUncertaintyReply)
        var control=request;control.reviewedCatalog=nil
        do {_ = try await isolatedLocal.analyze(control)} catch {}
        check("local transport positive control is observed",!ReviewedMockProtocol.requests.isEmpty)
        for question:String? in [nil,"", "   "] {
            var ambient=request;ambient.currentQuestion=question;ambient.reviewedQuestionKey=nil
            ReviewedMockProtocol.requests=[];ReviewedMockProtocol.bodies=[]
            let claudeAmbient=try await provider.analyze(ambient)
            let localAmbient=try await isolatedLocal.analyze(ambient)
            let factoryAmbient=try await switching.analyze(ambient)
            check("reviewed ambient cannot generate facts",claudeAmbient.insights.isEmpty && localAmbient.insights.isEmpty && factoryAmbient.insights.isEmpty && ReviewedMockProtocol.requests.isEmpty)
        }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("parrot-reviewed-store-test-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let libraryURL=folder.appendingPathComponent("reviewed.json")
        let store=ReviewedAnswerStore(url:libraryURL)
        func rejectsLoad(_ candidate:ReviewedAnswerStore)->Bool {
            do {_ = try candidate.load();return false} catch {return true}
        }
        let freshLibrary=try store.load()
        check("fresh store has no reviewed intent",!store.isConfigured && freshLibrary==nil)
        do {_ = try store.install(Data("invalid".utf8));check("first invalid import rejected",false)}
        catch {check("first invalid import rejected",true)}
        let reopenedInvalid=ReviewedAnswerStore(url:libraryURL)
        check("first failed import remains required on reopen",reopenedInvalid.isConfigured && rejectsLoad(reopenedInvalid))
        _ = try store.install(ReviewedAnswerTests.fixtureData)
        check("valid library survives store reopen",try ReviewedAnswerStore(url:libraryURL).load()?.answers.first?.id==answer.id)
        do {_ = try store.install(Data("invalid replacement".utf8));check("invalid replacement rejected",false)}
        catch {check("invalid replacement rejected",true)}
        check("invalid replacement preserves original bytes",try Data(contentsOf:libraryURL)==ReviewedAnswerTests.fixtureData)
        check("old verified library stays usable after replacement failure",try store.load()?.answers.first?.id==answer.id)
        try FileManager.default.removeItem(at:libraryURL)
        check("missing library remains required on reopen",ReviewedAnswerStore(url:libraryURL).isConfigured && rejectsLoad(ReviewedAnswerStore(url:libraryURL)))
        try Data("corrupt saved file".utf8).write(to:libraryURL)
        check("corrupt saved library rejected on reopen",rejectsLoad(ReviewedAnswerStore(url:libraryURL)))
        let migratedURL=folder.appendingPathComponent("legacy-reviewed.json")
        try ReviewedAnswerTests.fixtureData.write(to:migratedURL)
        let migrated=ReviewedAnswerStore(url:migratedURL)
        check("legacy library starts without intent marker",!FileManager.default.fileExists(atPath:migrated.requiredURL.path))
        _ = try migrated.load()
        try FileManager.default.removeItem(at:migratedURL)
        check("legacy library load persists intent before later loss",ReviewedAnswerStore(url:migratedURL).isConfigured && rejectsLoad(ReviewedAnswerStore(url:migratedURL)))
        let corruptLegacyURL=folder.appendingPathComponent("legacy-corrupt.json")
        try Data("legacy invalid".utf8).write(to:corruptLegacyURL)
        let corruptLegacy=ReviewedAnswerStore(url:corruptLegacyURL)
        check("legacy corrupt library is rejected",rejectsLoad(corruptLegacy))
        try FileManager.default.removeItem(at:corruptLegacyURL)
        check("legacy corrupt load also persists required mode",ReviewedAnswerStore(url:corruptLegacyURL).isConfigured)
        try await MainActor.run {
            let kbFolder=folder.appendingPathComponent("kb-integration",isDirectory:true)
            try FileManager.default.createDirectory(at:kbFolder,withIntermediateDirectories:true)
            let index=kbFolder.appendingPathComponent("index.json")
            let first=KnowledgeBaseService(storageURL:index)
            check("KB fresh strict mode is unconfigured",first.reviewedAnswerSnapshot(for:nil)==nil)
            do {try first.installReviewedCatalog(Data("invalid".utf8));check("KB rejects invalid first library",false)}
            catch {check("KB rejects invalid first library",true)}
            let failedReopen=KnowledgeBaseService(storageURL:index)
            check("KB failed first import reopens unavailable",failedReopen.reviewedAnswerSnapshot(for:nil)?.answers.isEmpty==true)
            try failedReopen.installReviewedCatalog(ReviewedAnswerTests.fixtureData)
            failedReopen.seedForSnapshot(documents:[doc])
            _ = failedReopen.createFolder(name:"Synthetic test only")
            let reopened=KnowledgeBaseService(storageURL:index)
            check("KB source and signed library reopen together",reopened.reviewedAnswerSnapshot(for:nil)?.answers.first?.id==answer.id)
            check("KB persists original imported fingerprint",reopened.documents.first?.contentSHA256==source.sha256)
            reopened.setScope(.off,for:reopened.documents[0])
            let offReopen=KnowledgeBaseService(storageURL:index)
            check("KB disabled source remains unavailable on reopen",offReopen.reviewedAnswerSnapshot(for:nil)?.answers.isEmpty==true)
            try FileManager.default.removeItem(at:kbFolder.appendingPathComponent("reviewed-answers.json"))
            let missingReopen=KnowledgeBaseService(storageURL:index)
            check("KB missing configured library never becomes legacy",missingReopen.reviewedAnswerSnapshot(for:nil)?.answers.isEmpty==true)
        }
        print("REVIEWED_PROVIDER_TRANSPORT_CHECKS \(count) FAILURES \(failed); mock HTTP + actual provider/privacy sources, not semantic or native acceptance")
    }
}

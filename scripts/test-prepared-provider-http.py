#!/usr/bin/env python3
"""Actual production HTTP method + comparison metadata, fictional URLProtocol only."""
from pathlib import Path
import argparse, platform, subprocess, tempfile, hashlib, json
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work-root", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source_paths = [root / p for p in ["Parrot/Services/AnalysisProvider.swift", "Parrot/Services/AnswerTrace.swift",
    "Parrot/Services/RepositoryPromptCache.swift", "Parrot/Services/PreparedProviderHTTP.swift",
    "scripts/test-prepared-provider-http.py"]]
source_hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
print(json.dumps({"scope":"fictional HTTP component only", "source_sha256":source_hashes},sort_keys=True),flush=True)
provider = (root / "Parrot/Services/AnalysisProvider.swift").read_text()
def method(marker):
    start = provider.index(marker)
    return provider[start:provider.index("\n    }", start) + len("\n    }")]
trace = (root / "Parrot/Services/AnswerTrace.swift").read_text()
metadata = trace[trace.index("struct AnswerTraceHTTPResponse:"):trace.index("/// Retained by a request")]
cache = (root / "Parrot/Services/RepositoryPromptCache.swift").read_text()
cache = cache[cache.index("    static func encodedBody("):]
subject = """
import Foundation
struct AnswerTraceLink {
 enum Stage { case requestSent }
 func mark(_ stage: Stage, model: String?) {}
 func receivedHTTPResponse(statusCode: Int?, data: Data, requestedModel: String) {}
}
enum AnalysisError: Error { case badResponse(String) }
final class Subject {
 static let model = "claude-haiku-5-5"
 let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
 let session: URLSession
 var metered = 0
 init(_ session: URLSession) { self.session = session }
 func recordUsage(from data: Data) { metered += 1 }
 func request(_ body: [String:Any], retry: Bool = false,
              observer: ((Int?,Data?,UInt64,UInt64,Data)->Void)? = nil) async throws -> Data {
  try await performRequest(body:body,apiKey:"public-fixture-not-a-secret",timeout:1,
                           retryTransient:retry,repositoryContext:true,observingHTTP:observer)
 }
""" + method("    private func performRequest(") + "\n" + method("    private static func errorMessage(") + """
}
enum RepositoryPromptCache {
 enum Failure: Error { case held(String) }
 static let maximumEncodedBytes = 768 * 1024, maximumTokenUpperBound = 900_000
""" + cache
main = r'''
import Foundation
import CryptoKit
final class MockHTTP: URLProtocol {
 struct Plan {
  let status: Int?, data: Data, error: URLError?, split: Bool
  init(_ status: Int? = 200, _ data: Data, error: URLError? = nil, split: Bool = false) {
   self.status=status; self.data=data; self.error=error; self.split=split
  }
 }
 static let lock=NSLock()
 static var plans:[Plan]=[], sent:[Data]=[], unexpected=0
 override class func canInit(with request:URLRequest)->Bool { true }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() {
  Self.lock.lock()
  guard request.url?.absoluteString=="https://api.anthropic.com/v1/messages",!Self.plans.isEmpty else {
   Self.unexpected += 1; Self.lock.unlock()
   client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
  }
  let plan=Self.plans.removeFirst()
  var body=request.httpBody ?? Data()
  if body.isEmpty,let stream=request.httpBodyStream {
   stream.open();defer {stream.close()}
   var buffer=[UInt8](repeating:0,count:65536)
   while true {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};body.append(contentsOf:buffer.prefix(n))}
  }
  Self.sent.append(body);Self.lock.unlock()
  if let error=plan.error {client?.urlProtocol(self,didFailWithError:error);return}
  let response:URLResponse
  if let status=plan.status {
   response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!
  } else {response=URLResponse(url:request.url!,mimeType:"application/json",expectedContentLength:plan.data.count,textEncodingName:"utf-8")}
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
  if plan.split {
   let i=plan.data.count/2
   client?.urlProtocol(self,didLoad:Data(plan.data.prefix(i)))
   Thread.sleep(forTimeInterval:0.03)
   client?.urlProtocol(self,didLoad:Data(plan.data.suffix(plan.data.count-i)))
  } else {client?.urlProtocol(self,didLoad:plan.data)}
  client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
 static func enqueue(_ plan:Plan) {lock.lock();plans.append(plan);lock.unlock()}
 static func count()->Int {lock.lock();defer {lock.unlock()};return sent.count}
}
var checks=0,failures=0
func check(_ name:String,_ value:Bool) {checks+=1;if !value {failures+=1;print("FAIL "+name)}}
func json(_ object:[String:Any])->Data {try! JSONSerialization.data(withJSONObject:object,options:.sortedKeys)}
func response(model:String?="claude-haiku-5-5",usage:[String:Any]?=nil,text:String="fixture response",stop:String="end_turn")->Data {
 var value:[String:Any]=["content":[["type":"text","text":text]],"stop_reason":stop]
 if let model {value["model"]=model};if let usage {value["usage"]=usage};return json(value)
}
func body(_ id:Int)->[String:Any] {["model":"claude-haiku-5-5","max_tokens":220,"temperature":0,
                                  "messages":[["role":"user","content":"fictional \(id)"]]]}
func encoded(_ result:PreparedProviderHTTP.Result)->[String:Any] {
 let data=try! JSONEncoder().encode(result)
 let text=String(decoding:data,as:UTF8.self)
 check("measurement never logs key/URL/error message",!text.contains("public-fixture-not-a-secret") &&
       !text.contains("api.anthropic.com") && !text.contains("public-error-body-marker"))
 return try! JSONSerialization.jsonObject(with:data) as! [String:Any]
}
Task {
 let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[MockHTTP.self]
 let session=PreparedProviderHTTP.session(configuration:configuration)
 defer {session.invalidateAndCancel()}
 let subject=Subject(session)
 func run(_ request:[String:Any],_ plan:MockHTTP.Plan,expected:String?=nil) async ->PreparedProviderHTTP.Result {
  MockHTTP.enqueue(plan)
  let wire=try! RepositoryPromptCache.encodedBody(request,required:true)
  return await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",
          expectedWireSHA256:expected ?? PreparedProviderHTTP.sha(wire),expectedBytes:wire.count) { observer in
   try await subject.request(request,observer:observer)
  }
 }
 let usage:[String:Any]=["input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":400,
                        "cache_read_input_tokens":0,"cache_creation":["ephemeral_1h_input_tokens":400,"ephemeral_5m_input_tokens":0]]
 let first=await run(body(0),.init(200,response(usage:usage),split:true))
 check("first actual HTTP response is unscored",first.status=="response_unscored" && !first.nativeAcceptance && !first.scored)
 check("actual requested and returned model preserved",first.requestedModel=="claude-haiku-5-5" && first.returnedModel=="claude-haiku-5-5")
 check("full response timing includes final chunk",first.fullHTTPNanoseconds.map{$0>=20_000_000}==true && first.firstResponseText=="fixture response")
 check("actual sent bytes are hashed",first.actualRequestBytes==MockHTTP.sent[0].count && first.actualWireSHA256==PreparedProviderHTTP.sha(MockHTTP.sent[0]))
 check("per-response usage is not summed",first.usage.input==10 && first.usage.creation==400 && first.usage.read==0)
 check("actual cache TTL counters retained",first.usage.creationByTTL?["ephemeral_1h_input_tokens"]==400)
 _=encoded(first)
 let missing=await run(body(1),.init(200,response()))
 let missingJSON=encoded(missing),missingUsage=missingJSON["usage"] as! [String:Any]
 check("missing usage stays null and unknown",missing.usage.state=="missing" && missingUsage["input_tokens"] is NSNull && missingUsage["cache_read_input_tokens"] is NSNull && missingJSON["cacheClassification"] as? String=="unknown")
 let zero=await run(body(2),.init(200,response(usage:["cache_read_input_tokens":0,"cache_creation_input_tokens":0])))
 check("explicit zeros remain distinct from missing",zero.usage.cacheClassification=="reported_zero_read_and_creation")
 let warm=await run(body(3),.init(200,response(usage:["cache_read_input_tokens":100,"cache_creation_input_tokens":0])))
 check("cache read classification requires actual usage",warm.usage.cacheClassification=="observed_cache_read")
 let malformedUsage=await run(body(4),.init(200,response(usage:["input_tokens":true,"output_tokens":-1,"cache_read_input_tokens":2.5])))
 check("malformed counters never become zeros",malformedUsage.usage.state=="invalid" && malformedUsage.usage.input==nil && malformedUsage.usage.output==nil && malformedUsage.usage.read==nil && malformedUsage.usage.cacheClassification=="unknown")
 for status in [400,401,429,500,503] {
  let before=MockHTTP.count()
  let failed=await run(body(status),.init(status,json(["error":["message":"public-error-body-marker"]])))
  check("first HTTP failure retained without retry",failed.status=="http_error" && failed.httpStatus==status && failed.appAttempts==1 && MockHTTP.count()==before+1)
  check("error body only retained by hash/length",failed.retainedResponse==nil && failed.firstResponseText==nil && failed.responseSHA256 != nil && failed.usage.input==nil)
  _=encoded(failed)
 }
 let timed=await run(body(5),.init(200,Data(),error:URLError(.timedOut)))
 check("timeout has one observed app attempt",timed.status=="timeout" && timed.appAttempts==1 && timed.transportErrorCode==URLError.timedOut.rawValue && timed.fullHTTPNanoseconds != nil)
 let cancelled=await run(body(6),.init(200,Data(),error:URLError(.cancelled)))
 check("transport cancellation retained",cancelled.status=="cancelled" && cancelled.appAttempts==1)
 let invalidJSON=await run(body(7),.init(200,Data("{not-json".utf8)))
 check("invalid JSON not accepted as verified model",invalidJSON.status=="model_metadata_unverified" && invalidJSON.retainedResponse != nil)
 let noModel=await run(body(8),.init(200,response(model:nil)))
 check("missing returned model is honest",noModel.status=="model_metadata_unverified" && noModel.returnedModel==nil && noModel.modelState=="missing")
 let wrongModel=await run(body(9),.init(200,response(model:"claude-sonnet-5-5")))
 check("wrong returned model never guessed",wrongModel.status=="model_metadata_unverified" && wrongModel.returnedModel==nil && wrongModel.modelState=="unrecognized")
 let dated=await run(body(10),.init(200,response(model:"claude-haiku-5-5-20261001")))
 check("recognized returned dated model preserved",dated.returnedModel=="claude-haiku-5-5-20261001")
 let large=await run(body(11),.init(200,response(text:String(repeating:"x",count:20000))))
 check("post-buffer response limit rejects retention",large.status=="response_too_large" && large.retainedResponse==nil && large.responseBytes!>PreparedProviderHTTP.maximumRetainedResponseBytes && large.responseSHA256 != nil)
 var boundaryText=String(repeating:"/ \\n \\\" \\\\ ",count:4000)
 while response(text:boundaryText).count>PreparedProviderHTTP.maximumRetainedResponseBytes {boundaryText=String(boundaryText.dropLast(50))}
 let boundary=await run(body(110),.init(200,response(text:boundaryText)))
 check("largest retained response preserves exact first text",boundary.firstResponseText==boundaryText && boundary.retainedResponse != nil)
 check("bounded response fits existing journal row budget",try! JSONEncoder().encode(boundary).count<60*1024)
 let multiple=await run(body(111),.init(200,json(["model":"claude-haiku-5-5","content":[["type":"text","text":"First claim."],["type":"text","text":"Only when the required condition holds."]]])))
 check("complete first response includes every text block in order",multiple.firstResponseText=="First claim.\nOnly when the required condition holds.")
 let malformedBlock=await run(body(112),.init(200,json(["model":"claude-haiku-5-5","content":[["type":"text","text":"First claim."],["type":"text","text":false]]])))
 check("malformed later text block cannot produce a partial pass",malformedBlock.status=="response_text_missing" && malformedBlock.firstResponseText==nil)
 let slashText=String(repeating:"/",count:PreparedProviderHTTP.maximumRetainedResponseBytes-256)
 let slashData=try! JSONSerialization.data(withJSONObject:["model":"claude-haiku-5-5","content":[["type":"text","text":slashText]]],options:[.sortedKeys,.withoutEscapingSlashes])
 let slashBoundary=await run(body(113),.init(200,slashData))
 check("worst slash expansion fits journal row reserve",slashBoundary.firstResponseText==slashText && (try! JSONEncoder().encode(slashBoundary)).count<60*1024)
 let wireMismatch=await run(body(12),.init(200,response()),expected:String(repeating:"0",count:64))
 check("actual wire mismatch is not a pass",wireMismatch.status=="observation_invalid_or_not_started")
 let nonHTTP=await run(body(13),.init(nil,response()))
 check("non HTTP response retained as failure",nonHTTP.status=="transport_error" && nonHTTP.httpStatus==nil)
 let wrongBody:[String:Any]=["model":"claude-sonnet-5-5","max_tokens":220]
 let wrongRequested=await run(wrongBody,.init(200,response()))
 check("requested model is observed from actual wire",wrongRequested.status=="requested_model_unverified" && wrongRequested.requestedModel==nil)
 let duplicateBody=try! RepositoryPromptCache.encodedBody(body(14),required:true),good=response()
 let duplicate=await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",
            expectedWireSHA256:PreparedProviderHTTP.sha(duplicateBody),expectedBytes:duplicateBody.count) { observer in
  observer(200,good,1,2,duplicateBody);observer(200,good,3,4,duplicateBody);return good
 }
 check("duplicate callbacks rejected",duplicate.appAttempts==2 && duplicate.status=="observation_invalid_or_not_started")
 let notStarted=await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",
            expectedWireSHA256:"",expectedBytes:0) { _ in throw CancellationError() }
 check("cancellation before attempt never fabricates timing",notStarted.status=="cancelled" && notStarted.appAttempts==0 && notStarted.fullHTTPNanoseconds==nil && notStarted.requestedModel==nil)
 let preCancelled=Task { () -> (PreparedProviderHTTP.Result,Int) in
  withUnsafeCurrentTask { $0?.cancel() }
  var sends=0
  let result=await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",expectedWireSHA256:"",expectedBytes:0) { _ in
   sends+=1;return good
  }
  return (result,sends)
 }
 let pre=await preCancelled.value
 check("already cancelled task never enters send",pre.0.status=="cancelled" && pre.0.cancellationObserved && pre.1==0 && pre.0.appAttempts==0)
 let postCancelled=Task {
  await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",expectedWireSHA256:PreparedProviderHTTP.sha(duplicateBody),expectedBytes:duplicateBody.count) { observer in
   observer(200,good,1,2,duplicateBody);withUnsafeCurrentTask { $0?.cancel() };return good
  }
 }
 let post=await postCancelled.value
 check("nonthrowing send cannot hide task cancellation",post.status=="cancelled" && post.cancellationObserved && post.firstResponseText=="fixture response" && post.appAttempts==1)
 let failureThenCancel=Task {
  await PreparedProviderHTTP.measure(invocationID:UUID(),model:"claude-haiku-5-5",expectedWireSHA256:PreparedProviderHTTP.sha(duplicateBody),expectedBytes:duplicateBody.count) { observer in
   let failure=json(["error":["message":"public-error-body-marker"]])
   observer(429,failure,1,2,duplicateBody);withUnsafeCurrentTask { $0?.cancel() };return failure
  }
 }
 let prior=await failureThenCancel.value
 check("later cancellation preserves captured HTTP failure",prior.status=="http_error" && prior.httpStatus==429 && prior.cancellationObserved && prior.retainedResponse==nil)
 let offset=MockHTTP.count()
 var actual:[String]=[]
 for i in 0..<15 {
  let mapped=(i==1 ? 0 : (i==8 ? 7:i))
  let result=await run(body(mapped),.init(200,response(text:"row\(i)")))
  actual.append(result.actualWireSHA256!)
  check("ordered comparison response preserved",result.firstResponseText=="row\(i)" && result.appAttempts==1)
 }
 check("all fifteen rows execute including duplicates",MockHTTP.count()==offset+15 && actual[0]==actual[1] && actual[7]==actual[8] && Set(actual).count==13)
 let delegate=session.delegate as? PreparedProviderHTTP.NoRedirect
 check("private session disables client caches/credentials/cookies",session.configuration.urlCache==nil && session.configuration.urlCredentialStorage==nil && !session.configuration.httpShouldSetCookies && delegate != nil)
 var redirect:URLRequest?=URLRequest(url:URL(string:"https://other.invalid")!)
 let task=session.dataTask(with:URL(string:"https://api.anthropic.com")!)
 delegate!.urlSession(session,task:task,willPerformHTTPRedirection:HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:nil)!,
     newRequest:redirect!) { redirect=$0 }
 task.cancel()
 check("redirect policy refuses followup request",redirect==nil)
 let beforeNormal=MockHTTP.count()
 MockHTTP.enqueue(.init(500,json(["error":["message":"fictional transient"]])))
 MockHTTP.enqueue(.init(200,response()))
 do {_=try await subject.request(body(100),retry:true)}catch {check("normal request retry returned",false)}
 check("normal opt-in retry behavior unchanged",MockHTTP.count()==beforeNormal+2)
 check("fixture intercepted every attempted URL",MockHTTP.unexpected==0 && MockHTTP.plans.isEmpty)
 print("PREPARED HTTP: \(checks) checks; \(failures) failures; fictional transport only; nativeAcceptance=false")
 exit(failures==0 ? 0:1)
}
dispatchMain()
'''
with tempfile.TemporaryDirectory(prefix="prepared-http-",dir=args.work_root) as folder:
    work=Path(folder)
    (work/"Subject.swift").write_text(subject+"\n"+metadata)
    (work/"main.swift").write_text(main)
    executable=work/"checks"
    sdk=subprocess.check_output(["xcrun","--sdk","macosx","--show-sdk-path"],text=True).strip()
    subprocess.run(["swiftc","-swift-version","5","-target",platform.machine()+"-apple-macosx14.0","-sdk",sdk,
                    str(root/"Parrot/Services/PreparedProviderHTTP.swift"),str(work/"Subject.swift"),str(work/"main.swift"),
                    "-o",str(executable)],check=True,timeout=60)
    undefined=subprocess.check_output(["nm","-u",str(executable)],text=True,timeout=10)
    for name in ["SecItemCopyMatching","SecItemAdd","SecItemUpdate","SecItemDelete","SecKeychainSetUserInteractionAllowed","SecKeychainGetUserInteractionAllowed"]:
        assert "_"+name not in undefined,"Refusing real credential function"
    result=subprocess.run([str(executable)],capture_output=True,text=True,timeout=30)
    assert all(hashlib.sha256(p.read_bytes()).hexdigest()==source_hashes[str(p.relative_to(root))] for p in source_paths), "source changed during checks"
    print(result.stdout,end="")
    if result.stderr: print(result.stderr,end="",file=__import__("sys").stderr)
    raise SystemExit(result.returncode)


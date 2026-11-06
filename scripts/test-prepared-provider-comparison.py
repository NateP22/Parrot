#!/usr/bin/env python3
"""Frozen input, ordered executor and actual provider seam; intercepted fictional HTTP only."""
from pathlib import Path
import argparse, hashlib, json, platform, subprocess, tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument("--work-root",type=Path,required=True)
p.add_argument("--frozen-packet",type=Path)
p.add_argument("--wire-result",type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
paths=["Parrot/PreparedProviderInput.swift","Parrot/PreparedProviderComparison.swift",
       "Parrot/ReviewedSelectorJournal.swift","Parrot/Services/PreparedProviderHTTP.swift",
       "Parrot/Services/AnalysisProvider.swift","Parrot/Services/RepositoryPromptCache.swift",
       "Parrot/Services/AnswerTrace.swift","Parrot/Services/QASetupLaunch.swift","scripts/test-prepared-provider-comparison.py",
       "Parrot/ParrotApp.swift"]
hashes={x:hashlib.sha256((root/x).read_bytes()).hexdigest() for x in paths}
print(json.dumps({"scope":"fictional component only; frozen admission optional, never sends real HTTP","source_sha256":hashes},sort_keys=True),flush=True)
provider=(root/paths[4]).read_text()
def method(marker):
    start=provider.index(marker)
    return provider[start:provider.index("\n    }",start)+6]
trace=(root/paths[6]).read_text()
metadata=trace[trace.index("struct AnswerTraceHTTPResponse:"):trace.index("/// Retained by a request")]
comparison=(root/paths[1]).read_text()
core=comparison[:comparison.index("    // MARK: App-only session")]+"}\n"
core=core.replace("import Security\n","")
cache=(root/paths[5]).read_text()
cache="import Foundation\nenum RepositoryPromptCache {\nenum Failure:Error {case held(String)}\nstatic let maximumEncodedBytes=768*1024, maximumTokenUpperBound=900_000\n"+cache[cache.index("    static func encodedBody("):]
launch=(root/paths[7]).read_text()
# Static seam/order assertions supplement executed pure admission; not full app proof.
entry=(root/"Parrot/ParrotApp.swift").read_text()
assert entry.index("PreparedProviderComparison.run") < entry.index("ParrotApp.main()")
session=comparison[comparison.index("    @MainActor private static func session"):]
assert session.index("PreparedProviderInput.prepare") < session.index("guard let key = await APIKeyStore.loadInBackground")
assert session.index("ParrotSourceCommit") < session.index("APIKeyStore.loadInBackground")
assert "allowInteraction: false" in session and "!APIKeyStore.isSessionOnly" in session
assert session.count("try checkCloudRoute()") == 2 and "canSend: checkCloudRoute" in session
assert "expectedPacketSHA256: \"3d880dee0a4ec15bce177bf49c2bf162bd67cbd40de996bc68c7ed3af2ccb008\"" in session
assert "SecKeychainSetUserInteractionAllowed(false)" in session and "!interaction.boolValue" in session
stubs=r'''
import Foundation
struct AnswerTraceLink {
 enum Stage {case requestSent}
 func mark(_ stage:Stage,model:String?) {}
 func receivedHTTPResponse(statusCode:Int?,data:Data,requestedModel:String) {}
}
enum AnalysisError:Error {case missingAPIKey,badResponse(String)}
enum CloudGate {
 @TaskLocal static var scopeLocal=false
 static var fakeGlobalLocal=false
 static var forcesLocal:Bool {scopeLocal || fakeGlobalLocal}
}
enum SwitchingAnalysisProvider {
 enum Kind {case claude,local}
 static var liveKind=Kind.claude
}
enum QACredentialProbePolicy {static func request(options:[String])->String? {nil}}
final class ClaudeAnalysisProvider {
 static let model="claude-haiku-5-5"
 let endpoint=URL(string:"https://api.anthropic.com/v1/messages")!
 let session:URLSession
 let keyProvider:()->String?
 init(session:URLSession,keyProvider:@escaping()->String?={"public-fictional-fixture"}) {
  self.session=session;self.keyProvider=keyProvider
 }
 func recordUsage(from data:Data) {}
''' + method("    func sendPreparedComparison(") + "\n" + method("    private func performRequest(")+"\n"+method("    private static func errorMessage(")+"\n}\n"
allowed_start=trace.index("    static func isAllowed(")
allowed_end=trace.index("\n    }",allowed_start)+6
stubs+="\nimport CoreFoundation\nenum AnswerTraceRecorder {\n"+trace[allowed_start:allowed_end]+"\n}\n"
main=r'''
import Foundation
import CryptoKit
import Darwin
var failures=0,checks=0
func check(_ label:String,_ success:Bool) {checks+=1;print((success ? "PASS ":"FAIL ")+label);if !success {failures+=1}}
func rejects(_ label:String,_ body:()throws->Void) {do {try body();check(label,false)}catch {check(label,true)}}
func asyncRejects(_ label:String,_ body:()async throws->Void) async {do {try await body();check(label,false)}catch {check(label,true)}}
func bytes(_ obj:Any)throws->Data {try JSONSerialization.data(withJSONObject:obj,options:.sortedKeys)}
let base=URL(fileURLWithPath:CommandLine.arguments[1])
let model=ClaudeAnalysisProvider.model
func put(_ data:Data,_ url:URL)throws {try data.write(to:url);guard chmod(url.path,0o600)==0 else {throw NSError(domain:"fixture",code:1)}}
struct Fixture {
 let group:URL,packet:[ [String:Any] ],manifest:[String:Any],packetSHA:String
 var url:URL {group.appendingPathComponent("manifest.json")}
 func load(_ expected:String?=nil)throws->PreparedProviderInput.Prepared {
  try PreparedProviderInput.prepare(manifestURL:url,allowedRoot:base,model:model,expectedPacketSHA256:expected ?? packetSHA)
 }
}
func fixture(_ alter: (inout [[String:Any]])->Void = {_ in}) throws ->Fixture {
 let group=base.appendingPathComponent("fixture-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:group,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
 var packet:[[String:Any]]=[]
 for i in 0..<15 {
  let c=i/5,v=i%5
  // 13 unique bodies; preserve two intentional pairs as separate ordered calls.
  let context="Fictional raw code é🦜 / \"\n "+String(c)+"-"+String((c==0 && v==1) || (c==1 && v==3) ? v-1 : v)
  let body:[String:Any]=["model":model,"max_tokens":220,"temperature":0,
   "system":[["type":"text","text":"Fictional code-primary answer instructions.","cache_control":["type":"ephemeral","ttl":"1h"]]],
   "cache_control":["type":"ephemeral"],
   "messages":[["role":"user","content":[["type":"text","text":context,"cache_control":["type":"ephemeral","ttl":"1h"]],["type":"text","text":"Acknowledge the original code context."]]],
               ["role":"assistant","content":"Original code context loaded."],
               ["role":"user","content":"Fictional question "+String(c)+"?"]]]
  let wire=try RepositoryPromptCache.encodedBody(body,required:true)
  packet.append(["case_id":"case-"+String(c),"variant":"arm-"+String(v),"payload_sha256":PreparedProviderInput.sha(wire),
                 "bytes":wire.count,"stable_context_sha256":PreparedProviderInput.sha(Data(context.utf8)),"body":body])
 }
 alter(&packet)
 let packetData=try bytes(packet),packetSHA=PreparedProviderInput.sha(packetData)
 let mapping=try packet.enumerated().map { i,row -> [String:Any] in
  let wire=try RepositoryPromptCache.encodedBody(row["body"] as! [String:Any],required:true)
  return ["ordinal":i+1,"case_id":row["case_id"]!,"variant":row["variant"]!,"payload_sha256":row["payload_sha256"]!,
          "wire_sha256":PreparedProviderInput.sha(wire),"wire_bytes":wire.count]
 }
 let m:[String:Any]=["schema":1,"build_commit":String(repeating:"a",count:40),
  "packet":["path":"requests.json","sha256":packetSHA],"wire_rows":mapping,
  "source_repository_commit":String(repeating:"b",count:40),"source_packet_sha256":String(repeating:"c",count:64),
  "wire_qualification_sha256":String(repeating:"d",count:64)]
 try put(packetData,group.appendingPathComponent("requests.json"));try put(bytes(m),group.appendingPathComponent("manifest.json"))
 return Fixture(group:group,packet:packet,manifest:m,packetSHA:packetSHA)
}
final class MockHTTP:URLProtocol {
 static var sent=0,statuses:[Int]=[],unexpected=0,requestHashes:[String]=[]
 override class func canInit(with request:URLRequest)->Bool {true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
 override func startLoading() {
  guard request.url?.absoluteString=="https://api.anthropic.com/v1/messages" else {
   Self.unexpected+=1;client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
  }
  Self.sent+=1
  let code=Self.statuses.isEmpty ? 200:Self.statuses.removeFirst()
  let data=try! JSONSerialization.data(withJSONObject:["model":model,"stop_reason":"end_turn",
   "content":[["type":"text","text":"Fictional first reply."]],"usage":["input_tokens":100,"output_tokens":5]])
  let response=HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:[:])!
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
 static func reset(_ statuses:[Int]=[]) {sent=0;self.statuses=statuses;unexpected=0}
}
func runLoop(_ prepared:PreparedProviderInput.Prepared,_ provider:ClaudeAnalysisProvider,
             canSend:()throws->Void=PreparedProviderComparison.checkCloudRoute,
             record:@escaping(PreparedProviderComparison.Row)throws->Void) async throws {
 try await PreparedProviderComparison.execute(prepared:prepared,canSend:canSend,send:{item,id in
  await PreparedProviderHTTP.measure(invocationID:id,model:model,expectedWireSHA256:item.wireSHA256,
                                    expectedBytes:item.wireData.count) {observer in
   try await provider.sendPreparedComparison(body:item.body,observingHTTP:observer)
  }
 },record:record)
}
Task {
 do {
  let f=try fixture(), prepared=try f.load()
  check("all fifteen admitted; thirteen wire identities; duplicates retained",prepared.rows.count==15 && Set(prepared.rows.map(\.wireSHA256)).count==13)
  check("declared original metadata and actual wire data remain distinct fields",prepared.rows[0].declaredLogicalBytes>0 && prepared.rows[0].wireData.count>0)
  rejects("external frozen packet pin refuses self-consistent alternate packet") {_ = try f.load(String(repeating:"0",count:64))}
  let extra=try fixture();try put(Data("oracle".utf8),extra.group.appendingPathComponent("SCORING-CONTRACT.json"))
  rejects("unexpected oracle file rejected") {_ = try extra.load()}
  let existing=try fixture();try put(Data("previous".utf8),existing.group.appendingPathComponent("results.jsonl"))
  do {_ = try existing.load();check("existing output refuses overwrite",false)}catch PreparedProviderInput.Failure.outputExists {check("existing output refuses overwrite",true)}
  let insecure=try fixture();chmod(insecure.group.appendingPathComponent("requests.json").path,0o644)
  rejects("world-readable packet refused") {_ = try insecure.load()}
  let hard=try fixture();let hardFile=hard.group.appendingPathComponent("requests.json")
  let other=base.appendingPathComponent("hard-link-"+UUID().uuidString)
  guard link(hardFile.path,other.path)==0 else {throw NSError(domain:"fixture",code:2)}
  rejects("multiply-linked packet refused") {_ = try hard.load()}
  let symbolic=try fixture(),symPacket=symbolic.group.appendingPathComponent("requests.json")
  let original=base.appendingPathComponent("symlink-target-"+UUID().uuidString)
  try FileManager.default.moveItem(at:symPacket,to:original);try FileManager.default.createSymbolicLink(at:symPacket,withDestinationURL:original)
  rejects("symlinked packet refused") {_ = try symbolic.load()}
  let publicGroup=try fixture();chmod(publicGroup.group.path,0o755)
  rejects("nonprivate group refused") {_ = try publicGroup.load()}
  let changed=try fixture();try put(Data("[]".utf8),changed.group.appendingPathComponent("requests.json"))
  rejects("changed pinned packet refused") {_ = try changed.load()}
  let short=try fixture {$0.removeLast()}
  rejects("incomplete fifteen-row inventory refused") {_ = try short.load()}
  let badFinal=try fixture {rows in var b=rows[14]["body"] as! [String:Any];b["model"]="unapproved-model";rows[14]["body"]=b}
  rejects("malformed final row refuses entire preparation") {_ = try badFinal.load()}
  let duplicate=try fixture {$0[14]["variant"]=$0[13]["variant"]}
  rejects("duplicate case-arm pair refused") {_ = try duplicate.load()}
  let changedQuestion=try fixture {rows in
   var b=rows[14]["body"] as! [String:Any],m=b["messages"] as! [[String:Any]]
   m[2]["content"]="Different question?";b["messages"]=m;rows[14]["body"]=b
  }
  rejects("arms with different questions refused") {_ = try changedQuestion.load()}
  let badStable=try fixture {$0[14]["stable_context_sha256"]=String(repeating:"0",count:64)}
  rejects("last-row source-context digest mismatch refused") {_ = try badStable.load()}
  let wrongWire=try fixture();var wrongM=wrongWire.manifest,wrongRows=wrongM["wire_rows"] as! [[String:Any]]
  wrongRows[14]["wire_sha256"]=String(repeating:"0",count:64);wrongM["wire_rows"]=wrongRows
  try put(bytes(wrongM),wrongWire.url)
  rejects("last-row actual wire hash mismatch refused") {_ = try wrongWire.load()}
  let unknown=try fixture();var unknownM=unknown.manifest;unknownM["oracle"]="forbidden"
  try put(bytes(unknownM),unknown.url);rejects("unknown manifest field refused") {_ = try unknown.load()}
  let qa=QASetupLaunch.bundleID,path=f.url.path
  for (label,args,bundle,flag,expected) in [
   ("exact QA command",["qa","--qa-setup","--prepared-provider-comparison",path],qa,true,QASetupLaunch.Decision.settingsOnly),
   ("missing setup",["qa","--prepared-provider-comparison",path],qa,true,.rejected),
   ("production identity",["qa","--qa-setup","--prepared-provider-comparison",path],"com.uygar.parrot",true,.rejected),
   ("trace disabled",["qa","--qa-setup","--prepared-provider-comparison",path],qa,false,.rejected),
   ("relative manifest",["qa","--qa-setup","--prepared-provider-comparison","relative.json"],qa,true,.rejected),
   ("extra command",["qa","--qa-setup","--prepared-provider-comparison",path,"--capture-test"],qa,true,.rejected)
  ] {
   check("CLI admission "+label,QASetupLaunch.decision(arguments:args,bundleID:bundle,flag:flag,nextLaunch:false)==expected)
  }
  check("prepared CLI refuses numeric trace flag",
   QASetupLaunch.decision(arguments:["qa","--qa-setup","--prepared-provider-comparison",path],
    bundleID:qa,flag:NSNumber(value:1),nextLaunch:false) == .rejected)
  check("prepared CLI refuses malformed default flag",
   QASetupLaunch.decision(arguments:["qa","--qa-setup","--prepared-provider-comparison",path],
    bundleID:qa,flag:true,defaultFlag:"true",nextLaunch:false) == .rejected)
  let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockHTTP.self]
  let http=PreparedProviderHTTP.session(configuration:config)
  let provider=ClaudeAnalysisProvider(session:http)
  MockHTTP.reset();var recorded=0,ids=Set<UUID>()
  let journal=try ReviewedSelectorJournal(url:prepared.resultURL,header:["scope":"fictional-unscored"],expectedRows:15)
  try await runLoop(prepared,provider,canSend:{
   check("prior result recorded before send "+String(MockHTTP.sent+1),recorded==MockHTTP.sent)
   try PreparedProviderComparison.checkCloudRoute()
  },record:{row in
   try journal.append(row);recorded+=1;ids.insert(row.measurement.invocationID)
   check("complete first response preserved row "+String(row.ordinal),row.measurement.firstResponseText=="Fictional first reply." && row.measurement.fullHTTPNanoseconds != nil)
  })
  let receipt=try journal.finish()
  check("fifteen calls with distinct invocation IDs; no dedup",MockHTTP.sent==15 && ids.count==15)
  check("durable complete journal readback; unscored only",ReviewedSelectorJournal.verifies(receipt,at:prepared.resultURL))
  let journalText=try String(contentsOf:prepared.resultURL,encoding:.utf8)
  check("null cache state stays unknown; no false zero hit",journalText.contains("\"cacheClassification\":\"unknown\"") && journalText.contains("\"cache_read_input_tokens\":null"))
  check("completion footer does not claim native or scored acceptance",journalText.contains("\"nativeAcceptance\":false") && journalText.contains("\"scored\":false"))
  check("fixture credential absent from journal",!journalText.contains("public-fictional-fixture"))
  MockHTTP.reset([401]);var failedRows:[PreparedProviderComparison.Row]=[]
  await asyncRejects("first HTTP failure stops before second request") {try await runLoop(prepared,provider,record:{failedRows.append($0)})}
  check("first failed row retained and application did not retry",MockHTTP.sent==1 && failedRows.count==1 && failedRows[0].measurement.httpStatus==401)
  MockHTTP.reset()
  await asyncRejects("journal error stops before next send") {try await runLoop(prepared,provider,record:{_ in throw NSError(domain:"fixture",code:1)})}
  check("journal failure permits one request only",MockHTTP.sent==1)
  MockHTTP.reset();var privacyRows=0
  await asyncRejects("changed global privacy stops before next send") {
   try await runLoop(prepared,provider,record:{_ in privacyRows+=1;CloudGate.fakeGlobalLocal=true})
  }
  check("privacy rechecked between calls",MockHTTP.sent==1 && privacyRows==1);CloudGate.fakeGlobalLocal=false
  MockHTTP.reset()
  await CloudGate.$scopeLocal.withValue(true) {
   await asyncRejects("task-scoped privacy refuses any cloud send") {try await runLoop(prepared,provider,record:{_ in})}
  }
  check("task-scoped refusal made zero requests",MockHTTP.sent==0)
  SwitchingAnalysisProvider.liveKind = .local
  await asyncRejects("local route refuses cloud substitution") {try await runLoop(prepared,provider,record:{_ in})}
  check("route refusal made zero requests",MockHTTP.sent==0);SwitchingAnalysisProvider.liveKind = .claude
  MockHTTP.reset()
  let cancelled=Task {
   withUnsafeCurrentTask {$0?.cancel()}
   try await runLoop(prepared,provider,record:{_ in})
  }
  do {try await cancelled.value;check("pre-cancelled loop refused",false)}catch {check("pre-cancelled loop refused",true)}
  check("pre-cancelled loop made zero requests",MockHTTP.sent==0)
  MockHTTP.reset()
  let late=Task {
   var count=0
   do {
    try await runLoop(prepared,provider,record:{_ in count+=1;withUnsafeCurrentTask {$0?.cancel()}})
    check("cancel after durable row refuses next request",false)
   }catch {check("cancel after durable row refuses next request",count==1 && MockHTTP.sent==1)}
  }
  await late.value
  // Execute the actual seam's own privacy check, bypassing the loop guard.
  MockHTTP.reset();CloudGate.fakeGlobalLocal=true
  let denied=await PreparedProviderHTTP.measure(invocationID:UUID(),model:model,expectedWireSHA256:prepared.rows[0].wireSHA256,expectedBytes:prepared.rows[0].wireData.count) {o in
   try await provider.sendPreparedComparison(body:prepared.rows[0].body,observingHTTP:o)
  }
  check("provider seam independently refuses private send",MockHTTP.sent==0 && denied.appAttempts==0)
  CloudGate.fakeGlobalLocal=false
  check("no fixture request escaped intercepted endpoint",MockHTTP.unexpected==0)
  http.invalidateAndCancel()
  if CommandLine.arguments.count==3 {
   let realRoot=URL(fileURLWithPath:CommandLine.arguments[2])
   let real=try PreparedProviderInput.prepare(manifestURL:realRoot.appendingPathComponent("run/manifest.json"),
    allowedRoot:realRoot,model:model,expectedPacketSHA256:"3d880dee0a4ec15bce177bf49c2bf162bd67cbd40de996bc68c7ed3af2ccb008")
   check("actual frozen fifteen prepared without keys/network",real.rows.count==15 && Set(real.rows.map(\.wireSHA256)).count==13)
   check("actual frozen admission creates no response journal",!FileManager.default.fileExists(atPath:real.resultURL.path))
  }
 }catch {print("UNEXPECTED COMPONENT ERROR",String(reflecting:type(of:error)));failures+=1}
 print("COMPONENT CHECKS",checks,"FAILURES",failures,"NATIVE PASSES 0 REAL PROVIDER CALLS 0")
 exit(failures==0 ? 0:1)
}
dispatchMain()
'''
with tempfile.TemporaryDirectory(prefix="prepared-comparison-",dir=a.work_root) as d:
    temp=Path(d);temp.chmod(0o700)
    fixture_root=temp/"fixtures";fixture_root.mkdir(mode=0o700)
    files=[("Input.swift",(root/paths[0]).read_text()),("Comparison.swift",core),("Journal.swift",(root/paths[2]).read_text()),
           ("HTTP.swift",(root/paths[3]).read_text()),("Metadata.swift","import Foundation\nimport CoreFoundation\n"+metadata),
           ("Cache.swift",cache),("Launch.swift",launch),("Provider.swift",stubs),("main.swift",main)]
    for name,content in files:(temp/name).write_text(content)
    binary=temp/"checks"
    sdk=subprocess.check_output(["xcrun","--sdk","macosx","--show-sdk-path"],text=True).strip()
    subprocess.run(["swiftc","-swift-version","5","-target",platform.machine()+"-apple-macosx14.0","-sdk",sdk,
                    *[str(temp/name) for name,_ in files],"-o",str(binary)],check=True,timeout=90)
    undefined=subprocess.check_output(["nm","-u",str(binary)],text=True,timeout=10)
    for symbol in ["SecItemCopyMatching","SecItemAdd","SecItemUpdate","SecItemDelete",
                   "SecKeychainSetUserInteractionAllowed","SecKeychainGetUserInteractionAllowed"]:
        assert "_"+symbol not in undefined, "Refusing native credential linkage: "+symbol
    command=[str(binary),str(fixture_root)]
    if a.frozen_packet or a.wire_result:
        assert a.frozen_packet and a.wire_result
        packet=a.frozen_packet.read_bytes();qualification=a.wire_result.read_bytes()
        assert hashlib.sha256(packet).hexdigest()=="3d880dee0a4ec15bce177bf49c2bf162bd67cbd40de996bc68c7ed3af2ccb008"
        assert hashlib.sha256(qualification).hexdigest()=="b0a1249685fe3dd9d21942cd160a7ad05ff8afdee4a5b30393e4534f1bb36ec2"
        qualified=json.loads(qualification)
        assert len(qualified["rows"])==15
        private=temp/"frozen";private.mkdir(mode=0o700)
        run=private/"run";run.mkdir(mode=0o700)
        (run/"requests.json").write_bytes(packet);(run/"requests.json").chmod(0o600)
        manifest={"schema":1,"build_commit":"a"*40,
          "packet":{"path":"requests.json","sha256":hashlib.sha256(packet).hexdigest()},
          "source_repository_commit":"f68adc934b856384b55ee9f8b1bfa0b92d8462a3",
          "source_packet_sha256":"9ddaee44d50e4f8ccb1c007f2ef2b2ef6c59697c1d55d6e83ff0b459a4e5971c",
          "wire_qualification_sha256":hashlib.sha256(qualification).hexdigest(),
          "wire_rows":[{"ordinal":i+1,"case_id":x["case_id"],"variant":x["variant"],
             "payload_sha256":x["preparation_payload_sha256"],"wire_sha256":x["production_encoded_sha256"],
             "wire_bytes":x["production_encoded_bytes"]} for i,x in enumerate(qualified["rows"])]}
        (run/"manifest.json").write_text(json.dumps(manifest,sort_keys=True));(run/"manifest.json").chmod(0o600)
        command.append(str(private))
    subprocess.run(command,check=True,timeout=60)
assert hashes=={x:hashlib.sha256((root/x).read_bytes()).hexdigest() for x in paths},"Source changed during run"
print("Exact source hashes unchanged; native authentication, inference and app acceptance remain unproved.",flush=True)

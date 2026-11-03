#!/usr/bin/env python3
"""Hermetic phase/ownership tests. Every Security call is shadowed and link-fenced."""
from pathlib import Path
import importlib.util
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import platform
root=Path(__file__).resolve().parents[1]
source=(root/"Parrot/Services/AnalysisProvider.swift").read_text()
helper="import Foundation\nimport Security\nimport LocalAuthentication\nimport os\n"+source[source.index("enum APIKeyStore {"):]
trace=(root/"Parrot/Services/AnswerTrace.swift").read_text()
start=trace.index("    static func isAllowed(")
end=trace.index("\n    }",start)+len("\n    }")
allowed="import Foundation\nimport CoreFoundation\nenum AnswerTraceRecorder {\n"+trace[start:end]+"\n}\n"
security=(root/"scripts/credential-regression.swift").read_text().split("var failures = 0")[0]
main=security+r'''
var setStatus: OSStatus = errSecSuccess, getStatus: OSStatus = errSecSuccess
var setCalls=0, getCalls=0
var reportedUI=false
func SecKeychainSetUserInteractionAllowed(_ value: Bool) -> OSStatus {
    setCalls += 1
    if value { fatalError("probe attempted to enable authentication UI") }
    return setStatus
}
func SecKeychainGetUserInteractionAllowed(_ value: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    getCalls += 1; value.pointee=DarwinBoolean(reportedUI); return getStatus
}
var failures=0
if let index=CommandLine.arguments.firstIndex(of:"--encoded-report"), index+1<CommandLine.arguments.count {
    let phase=CommandLine.arguments[index+1]
    let stages=["write":"saved","verify-cleanup":"verified_removed","absent":"absent"]
    guard let stage=stages[phase] else { exit(2) }
    let report=QACredentialProbe.Report(stage:stage,phase:phase,
        nonce:"01234567-89AB-4CDE-8FAB-0123456789AB",pid:ProcessInfo.processInfo.processIdentifier,
        status:phase=="absent" ? errSecItemNotFound:nil,
        userInteractionDisallowed:true,cleanupVerified:phase=="absent")
    FileHandle.standardOutput.write(try! JSONEncoder().encode(report)); exit(0)
}
func check(_ name:String,_ value:Bool) {
    print((value ? "PASS ":"FAIL ")+name); if !value { failures += 1 }
}
let eligible=QACredentialProbe.Environment(setupActive:true,
    bundleID:"com.uygar.parrot.sat54.qa",traceFlag:true,
    configuredService:"com.uygar.parrot.sat54.qa",sessionOnly:false)
func request(_ phase:QACredentialProbePolicy.Phase,
             nonce:UUID=UUID()) -> QACredentialProbePolicy.Request {
    QACredentialProbePolicy.Request(phase:phase,nonce:nonce)
}
func reset() {
    records=[:];blockedReads=[:];failedWrites=[];failedDeletes=[];raceOnAdd=[:]
    reads=[:];deletions=[:];additions=[:];updates=[:];services=[];dataRequests=[:];interactionRequests=[]
    setStatus=errSecSuccess;getStatus=errSecSuccess;setCalls=0;getCalls=0;reportedUI=false
}
func run(_ req:QACredentialProbePolicy.Request,
         _ env:QACredentialProbe.Environment=eligible) -> QACredentialProbe.Report {
    QACredentialProbe.execute(req,environment:env)
}
check("valid QA metadata is eligible",eligible.isEligible)
for env in [
    QACredentialProbe.Environment(setupActive:false,bundleID:eligible.bundleID,traceFlag:true,configuredService:eligible.configuredService,sessionOnly:false),
    QACredentialProbe.Environment(setupActive:true,bundleID:"com.uygar.parrot",traceFlag:true,configuredService:"com.uygar.parrot",sessionOnly:false),
    QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:NSNumber(value:1),configuredService:eligible.configuredService,sessionOnly:false),
    QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:"true",configuredService:eligible.configuredService,sessionOnly:false),
    QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:true,configuredService:"com.uygar.parrot",sessionOnly:false),
    QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:true,configuredService:eligible.configuredService,sessionOnly:true)
    ,QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:true,configuredService:eligible.configuredService,sessionOnly:NSNumber(value:0))
    ,QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:true,configuredService:eligible.configuredService,sessionOnly:"false")
    ,QACredentialProbe.Environment(setupActive:true,bundleID:eligible.bundleID,traceFlag:true,configuredService:eligible.configuredService,sessionOnly:nil)
] {
    reset();let report=run(request(.write),env)
    check("invalid environment rejected before all Security calls",
          report.stage=="rejected" && setCalls==0 && getCalls==0 && services.isEmpty)
}
reset();setStatus=errSecAuthFailed
check("UI suppression failure refuses",run(request(.write)).stage=="interaction_refused")
check("failed Set makes no Get or item call",getCalls==0 && services.isEmpty)
reset();getStatus=errSecParam
check("UI state read failure refuses",run(request(.write)).stage=="interaction_refused")
check("failed Get makes no item call",services.isEmpty)
reset();reportedUI=true
check("UI-enabled readback refuses",run(request(.write)).stage=="interaction_refused")
check("UI-enabled readback makes no item call",services.isEmpty)
reset()
let created=request(.write)
let saved=run(created)
check("write stores fixture through production API",saved.stage=="saved" && records[created.account]==Data(created.publicFixture.utf8))
check("write requires real missing metadata without data",dataRequests[created.account]==[false])
check("write uses atomic add only",additions[created.account]==1 && updates[created.account,default:0]==0)
check("write verifies process and per-operation suppression",setCalls==1 && getCalls==3 && saved.userInteractionDisallowed)
let verified=run(request(.verifyCleanup,nonce:created.nonce))
check("known fixture verification removes only owned account",verified.stage=="verified_removed" && records[created.account]==nil && deletions[created.account]==1)
check("verification cannot claim final cleanup",!verified.cleanupVerified)
let absent=run(request(.absent,nonce:created.nonce))
check("uncached absent phase proves cleanup",absent.stage=="absent" && absent.cleanupVerified)
check("each phase and its uncached operations gate authentication UI",setCalls==3 && getCalls==7)
check("every probe item query forbids authentication UI",!interactionRequests.isEmpty && interactionRequests.allSatisfy { $0==true })
let reportText=String(data:try! JSONEncoder().encode(saved),encoding:.utf8)!
check("report never contains credential fixture data",!reportText.contains(created.publicFixture))
reset()
let collision=request(.write);records[collision.account]=Data("public-foreign-value".utf8)
check("pre-existing entry aborts write",run(collision).stage=="collision")
check("collision never updates/adds/deletes",updates.isEmpty && additions.isEmpty && deletions.isEmpty)
check("collision data is retained",records[collision.account]==Data("public-foreign-value".utf8))
reset()
let racing=request(.write);raceOnAdd[racing.account]=Data(racing.publicFixture.utf8)
let raced=run(racing)
check("atomic duplicate preserves definitive collision status",raced.stage=="collision" && raced.status==errSecDuplicateItem)
check("same-fixture racing account is never deleted",deletions.isEmpty && records[racing.account]==Data(racing.publicFixture.utf8))
reset()
let blocked=request(.write);blockedReads[blocked.account]=errSecInteractionNotAllowed
check("metadata refusal aborts before save",run(blocked).stage=="metadata_refused")
check("metadata refusal never saves/deletes",updates.isEmpty && additions.isEmpty && deletions.isEmpty)
reset()
let writeFailure=request(.write);failedWrites.insert(writeFailure.account)
check("save failure cannot pass",run(writeFailure).stage=="write_failed")
reset()
let wrong=request(.verifyCleanup);records[wrong.account]=Data("public-not-our-fixture".utf8)
check("mismatch is not an owned credential",run(wrong).stage=="fixture_mismatch")
check("mismatch never deletes",deletions.isEmpty && records[wrong.account] != nil)
reset()
let inaccessible=request(.verifyCleanup);blockedReads[inaccessible.account]=errSecAuthFailed
check("unavailable verification fails safely",run(inaccessible).stage=="verification_unavailable")
check("unavailable verification never deletes",deletions.isEmpty)
reset()
let deletion=request(.verifyCleanup);records[deletion.account]=Data(deletion.publicFixture.utf8);failedDeletes.insert(deletion.account)
check("delete failure cannot pass",run(deletion).stage=="delete_failed")
check("failed delete retains fixture",records[deletion.account] != nil)
reset()
let uncertain=request(.absent);blockedReads[uncertain.account]=errSecInteractionNotAllowed
check("unknown cleanup is not absence",run(uncertain).stage=="cleanup_unverified")
check("cleanup query never requests password data",dataRequests[uncertain.account]==[false])
reset()
let remains=request(.absent);records[remains.account]=Data(remains.publicFixture.utf8)
check("still-existing entry fails cleanup",run(remains).stage=="cleanup_unverified")
check("absence check never deletes an entry",deletions.isEmpty)
print("PHASE CHECKS: \(failures) failures; mocked Security only, NOT native persistence")
exit(failures==0 ? 0:1)
'''
with tempfile.TemporaryDirectory(prefix="parrot-credential-probe-tests-") as directory:
    temp=Path(directory)
    (temp/"API.swift").write_text(helper)
    (temp/"Allowed.swift").write_text(allowed)
    (temp/"main.swift").write_text(main)
    app=temp/"Fixture.app"
    binary=app/"Contents/MacOS/checks";binary.parent.mkdir(parents=True)
    info={"CFBundleIdentifier":"com.uygar.parrot.sat54.qa","CFBundleExecutable":"checks",
          "CFBundlePackageType":"APPL","ParrotKeychainService":"com.uygar.parrot.sat54.qa",
          "ParrotSessionOnlyCredentials":False,"ParrotNativeAnswerTrace":True,"ParrotQASetupByDefault":True}
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    files=[temp/"API.swift",temp/"Allowed.swift",root/"Parrot/Services/QASetupLaunch.swift",
           root/"Parrot/Services/QACredentialProbePolicy.swift",root/"Parrot/QACredentialProbe.swift",temp/"main.swift"]
    boundary = main.index('check("valid QA metadata is eligible"')
    main = main[:boundary] + '\nfunc runPhaseChecks() {\n' + main[boundary:] + '\n}\nDispatchQueue.global().async { runPhaseChecks() }\ndispatchMain()\n'
    (temp/'main.swift').write_text(main)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(["swiftc","-D","PARROT_CUSTOM_LEGACY_SHIMS","-swift-version","5", '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk, *[str(p) for p in files],"-o",str(binary)],check=True)
    undefined=subprocess.check_output(["nm","-u",str(binary)],text=True)
    for name in ["SecItemCopyMatching","SecItemAdd","SecItemUpdate","SecItemDelete",
                 "SecKeychainSetUserInteractionAllowed","SecKeychainGetUserInteractionAllowed"]:
        if "_"+name in undefined:
            raise SystemExit("Refusing tests linked to real Security function "+name)
    print("Verified no real Security item/interaction functions are linked",flush=True)
    result=subprocess.run([str(binary)],timeout=15).returncode
    spec=importlib.util.spec_from_file_location("native_probe_runner",root/"scripts/run-native-credential-probe.py")
    runner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=runner;spec.loader.exec_module(runner)
    validator=runner.ProbeRunner(binary,"a"*64,"b"*40,state_path=temp/"state.json")
    failures=0
    for phase in ("write","verify-cleanup","absent"):
        child=subprocess.Popen([str(binary),"--encoded-report",phase],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        output,_=child.communicate(timeout=15)
        try:
            validator._validate({"report":json.loads(output),"pid":child.pid,"exit_code":child.returncode},
                                phase,"01234567-89AB-4CDE-8FAB-0123456789AB",set())
            print("PASS actual Swift report -> Python runner: "+phase)
        except runner.ProbeFailure as error:
            print("FAIL actual Swift report -> Python runner: "+phase+": "+str(error));failures+=1
    raise SystemExit(result or bool(failures))

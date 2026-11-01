#!/usr/bin/env python3
"""Bounded three-process QA Keychain probe; never real provider/answer acceptance."""
from pathlib import Path
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import selectors
import stat
import subprocess
import sys
import time
import uuid

SCHEMA="parrot-qa-native-keychain-run-v1"
QA_ID="com.uygar.parrot.sat54.qa"
FIELDS={"stage","phase","nonce","pid","status","userInteractionDisallowed",
        "cleanupVerified","nativeAcceptance","scope"}
EXPECTED={"write":"saved","verify-cleanup":"verified_removed","absent":"absent"}
KNOWN_STAGES=set(EXPECTED.values())|{"rejected","interaction_refused","collision","metadata_refused",
    "write_failed","verification_unavailable","fixture_mismatch","delete_failed","cleanup_unverified","timeout"}
class ProbeFailure(RuntimeError): pass
def sync_directory(path):
    fd=os.open(path,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
def ensure_directory(path):
    path=Path(path)
    if path.is_symlink():raise ProbeFailure("directory_symlink")
    if path.exists():
        if not path.is_dir():raise ProbeFailure("not_directory")
        return
    ensure_directory(path.parent)
    path.mkdir(mode=0o700)
    sync_directory(path.parent)
def digest(path):
    value=hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b""):value.update(chunk)
    return value.hexdigest()
def boot_id():
    try:return subprocess.check_output(["/usr/sbin/sysctl","-n","kern.bootsessionuuid"],text=True,timeout=3).strip()
    except (OSError,subprocess.SubprocessError):return None
def verify_bundle(binary,expected_sha,expected_source):
    binary=Path(binary).absolute()
    if binary.is_symlink() or not binary.is_file():raise ProbeFailure("binary_not_regular")
    app=binary.parents[2]
    if app.suffix!=".app" or binary.parent.name!="MacOS":raise ProbeFailure("not_app_binary")
    info_path=app/"Contents/Info.plist"
    if info_path.is_symlink():raise ProbeFailure("info_symlink")
    info=plistlib.loads(info_path.read_bytes())
    if (info.get("CFBundleIdentifier")!=QA_ID or info.get("ParrotKeychainService")!=QA_ID or
        info.get("ParrotSessionOnlyCredentials") is not False or
        info.get("ParrotNativeAnswerTrace") is not True or info.get("ParrotQASetupByDefault") is not True or
        type(info.get("ParrotQACredentialProbeVersion")) is not int or info["ParrotQACredentialProbeVersion"]!=1 or
        info.get("CFBundleExecutable")!=binary.name or info.get("ParrotSourceCommit")!=expected_source):
        raise ProbeFailure("bundle_metadata_mismatch")
    actual=digest(binary)
    if actual!=expected_sha:raise ProbeFailure("binary_digest_mismatch")
    checked=subprocess.run(["/usr/bin/codesign","--verify","--deep","--strict",str(app)],
                           capture_output=True,timeout=15)
    if checked.returncode:raise ProbeFailure("signature_failed")
    return {"binary_sha256":actual,"source_commit":expected_source,"info_sha256":digest(info_path)}
class ProbeRunner:
    def __init__(self,binary,expected_sha,expected_source,*,state_path=None,
                 verify=None,phase=None,boot_id=boot_id):
        if not re.fullmatch("[a-f0-9]{64}",expected_sha) or not re.fullmatch("[a-f0-9]{40}",expected_source):
            raise ProbeFailure("expected_identity_invalid")
        self.binary=Path(binary)
        self.expected_sha=expected_sha;self.expected_source=expected_source
        self.state_path=Path(state_path) if state_path else Path.home()/"Library/Application Support/Parrot SAT54 QA/native-keychain-probe-state-v1.json"
        self.verify=verify or (lambda:verify_bundle(self.binary,expected_sha,expected_source))
        self.phase=phase or self._native_phase
        self.boot_id=boot_id
        self._state_digest=None
    def _read(self):
        if not self.state_path.exists():
            if self.state_path.is_symlink():raise ProbeFailure("state_symlink")
            return None
        info=self.state_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_size>65536:
            raise ProbeFailure("state_not_private_regular")
        raw=self.state_path.read_bytes();self._state_digest=hashlib.sha256(raw).hexdigest()
        value=json.loads(raw)
        if not isinstance(value,dict):raise ProbeFailure("foreign_or_invalid_state")
        try:canonical=str(uuid.UUID(value["nonce"])).upper()==value["nonce"]
        except (KeyError,ValueError,TypeError):canonical=False
        if value.get("schema")!=SCHEMA or value.get("status") not in ("pending","complete","recovered","refused") or not canonical:
            raise ProbeFailure("foreign_or_invalid_state")
        return value
    def _save(self,value):
        encoded=(json.dumps(value,sort_keys=True,indent=2)+"\n").encode()
        if len(encoded)>65536:raise ProbeFailure("state_size_limit")
        if self._state_digest is not None and (not self.state_path.is_file() or digest(self.state_path)!=self._state_digest):
            raise ProbeFailure("concurrent_state_change")
        temp=self.state_path.with_name(self.state_path.name+"."+uuid.uuid4().hex+".tmp")
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            with os.fdopen(fd,"wb") as output:output.write(encoded);output.flush();os.fsync(output.fileno())
            if self._state_digest is None:os.link(temp,self.state_path)
            else:os.replace(temp,self.state_path)
        finally:
            if temp.exists():temp.unlink()
        sync_directory(self.state_path.parent)
        self._state_digest=hashlib.sha256(encoded).hexdigest()
        if self.state_path.read_bytes()!=encoded:raise ProbeFailure("state_readback_failed")
    def _validate(self,result,phase,nonce,seen):
        report=result.get("report")
        if not isinstance(report,dict) or set(report)!=FIELDS:raise ProbeFailure("report_fields")
        pid=result.get("pid")
        if type(pid) is not int or pid<=0 or pid in seen or report["pid"]!=pid:raise ProbeFailure("process_identity")
        if report["phase"]!=phase or report["nonce"]!=nonce:raise ProbeFailure("phase_correlation")
        if report["scope"]!="synthetic QA credential component only":raise ProbeFailure("phase_scope")
        stage=report["stage"] if isinstance(report["stage"],str) and report["stage"] in KNOWN_STAGES else "unknown"
        status=report["status"] if type(report["status"]) is int else None
        if report["userInteractionDisallowed"] is not True or report["nativeAcceptance"] is not False:
            raise ProbeFailure("phase_policy")
        if report["cleanupVerified"] is not (phase=="absent"):raise ProbeFailure("cleanup_claim")
        if result.get("exit_code")!=0:raise ProbeFailure("phase_exit:"+stage+":"+str(status))
        if report["stage"]!=EXPECTED[phase]:raise ProbeFailure("phase_failed:"+stage+":"+str(status))
        if phase=="absent" and (type(report["status"]) is not int or report["status"]!=-25300):
            raise ProbeFailure("cleanup_status_not_missing")
        return pid
    def _native_phase(self,phase,nonce,process):
        proc=subprocess.Popen([str(self.binary),"--qa-setup","--qa-credential-probe",phase,nonce],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        buffers={"out":bytearray(),"err":bytearray()};selector=selectors.DefaultSelector()
        try:
            process(proc.pid,False)
            selector.register(proc.stdout,selectors.EVENT_READ,"out")
            selector.register(proc.stderr,selectors.EVENT_READ,"err")
            deadline=time.monotonic()+10
            while selector.get_map():
                remaining=deadline-time.monotonic()
                if remaining<=0:raise ProbeFailure("phase_timeout")
                for key,_ in selector.select(min(remaining,0.2)):
                    chunk=os.read(key.fd,4096)
                    if not chunk:selector.unregister(key.fileobj);continue
                    target=buffers[key.data];target.extend(chunk)
                    if len(target)>(4096 if key.data=="out" else 8192):raise ProbeFailure("phase_output_limit")
            code=proc.wait(timeout=max(0.001,deadline-time.monotonic()))
            try:report=json.loads(bytes(buffers["out"]))
            except (ValueError,UnicodeError):raise ProbeFailure("phase_json")
            return {"report":report,"pid":proc.pid,"exit_code":code}
        except subprocess.TimeoutExpired as error:raise ProbeFailure("phase_timeout") from error
        finally:
            selector.close()
            if proc.poll() is None:proc.kill()
            try:proc.wait(timeout=5)
            finally:
                proc.stdout.close();proc.stderr.close()
            process(proc.pid,True)
    def run(self,recover=False):
        ensure_directory(self.state_path.parent)
        sync_directory(self.state_path.parent.parent)
        lock_path=self.state_path.with_suffix(".lock")
        fd=os.open(lock_path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
                raise ProbeFailure("lock_not_private")
            try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError as error:raise ProbeFailure("another_runner_active") from error
            identity=self.verify()
            if identity.get("binary_sha256")!=self.expected_sha or identity.get("source_commit")!=self.expected_source:
                raise ProbeFailure("artifact_identity_mismatch")
            previous=self._read()
            if previous and previous.get("status")=="pending":
                if previous.get("identity")!=identity:raise ProbeFailure("pending_artifact_changed")
                if not recover:return previous
                if not previous.get("process_terminal",False) and previous.get("boot_id")==self.boot_id():
                    pid=previous.get("current_pid")
                    if not pid:raise ProbeFailure("previous_process_unknown")
                    try:os.kill(pid,0)
                    except ProcessLookupError:pass
                    else:raise ProbeFailure("previous_process_still_present")
                state=previous
                state["results"]=[]
            elif recover:raise ProbeFailure("no_pending_run")
            else:
                if previous:
                    archive=self.state_path.parent/"native-keychain-probe-history"
                    ensure_directory(archive)
                    target=archive/(self._state_digest+".json")
                    raw=self.state_path.read_bytes()
                    if target.exists():
                        if target.read_bytes()!=raw:raise ProbeFailure("history_collision")
                    else:
                        handle=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
                        with os.fdopen(handle,"wb") as output:output.write(raw);output.flush();os.fsync(output.fileno())
                    sync_directory(archive)
                    sync_directory(self.state_path.parent)
                state={"schema":SCHEMA,"nonce":str(uuid.uuid4()).upper(),"identity":identity,
                       "status":"pending","results":[],"boot_id":self.boot_id(),
                       "process_terminal":True,"persistence_observed":False}
                self._save(state)
            seen=set()
            for phase in (["verify-cleanup","absent"] if recover else ["write","verify-cleanup","absent"]):
                state["current_phase"]=phase;state["current_pid"]=None;state["process_terminal"]=False
                self._save(state)
                def process(pid,terminal):
                    state["current_pid"]=pid;state["process_terminal"]=terminal;self._save(state)
                try:
                    if self.verify()!=identity:raise ProbeFailure("artifact_changed_before_phase")
                    result=self.phase(phase,state["nonce"],process)
                    pid=self._validate(result,phase,state["nonce"],seen)
                    if self.verify()!=identity:raise ProbeFailure("artifact_changed_after_phase")
                    seen.add(pid);state["results"].append(result["report"])
                except ProbeFailure as error:
                    # Both metadata collision and atomic-add duplicate are
                    # definitive pre-save refusals. Never delete their account,
                    # even if it contains the publicly derivable fixture.
                    if phase=="write" and str(error) in ("phase_exit:collision:0","phase_exit:collision:-25299") and result.get("exit_code")==1:
                        state["status"]="refused"
                        state["write_collision_not_owned"]=True
                    state["error"]=str(error);self._save(state)
                    if recover and phase=="verify-cleanup":continue
                    return state
                self._save(state)
            state["status"]="recovered" if recover else "complete"
            state["persistence_observed"]=not recover
            state["cleanup_verified"]=True
            state.pop("error",None)
            self._save(state)
            return state
        finally:os.close(fd)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary",type=Path)
    parser.add_argument("--expected-binary-sha256",required=True)
    parser.add_argument("--expected-source",required=True)
    parser.add_argument("--recover",action="store_true",help="Only clean the existing pending nonce; never proves persistence")
    args=parser.parse_args()
    try:
        result=ProbeRunner(args.binary,args.expected_binary_sha256,args.expected_source).run(recover=args.recover)
        print(json.dumps(result,sort_keys=True),flush=True)
        return 0 if result["status"]=="complete" else 2
    except (ProbeFailure,OSError,ValueError,subprocess.SubprocessError) as error:
        print(json.dumps({"status":"refused","reason":str(error)[:180],
                          "persistence_observed":False,"native_acceptance":False}),flush=True)
        return 2
if __name__=="__main__":raise SystemExit(main())

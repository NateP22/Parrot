#!/usr/bin/env python3
"""Runner/checkpoint boundary tests; phases are fictional, never native Keychain proof."""
from pathlib import Path
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from unittest import mock
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("probe_runner",root/"scripts/run-native-credential-probe.py")
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
class Checks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state=Path(self.temp.name)/"state.json"
        self.calls=[]
        self.pid=900000
        self.change=None
        self.fail_phase=None
        self.identity={"binary_sha256":"a"*64,"source_commit":"b"*40,"info_sha256":"c"*64}
    def phase(self,phase,nonce,process):
        self.calls.append((phase,nonce));self.pid+=1
        process(self.pid,False)
        if self.fail_phase==phase:
            process(self.pid,True)
            raise module.ProbeFailure("fixture phase failure")
        stage={"write":"saved","verify-cleanup":"verified_removed","absent":"absent"}[phase]
        result={"stage":stage,"phase":phase,"nonce":nonce,"pid":self.pid,
                "status":-25300 if phase=="absent" else None,
                "userInteractionDisallowed":True,"cleanupVerified":phase=="absent",
                "nativeAcceptance":False,"scope":"synthetic QA credential component only"}
        if self.change: self.change(phase,result)
        process(self.pid,True)
        return {"report":result,"pid":self.pid,"exit_code":0}
    def runner(self,**kwargs):
        return module.ProbeRunner(Path("/fixture/Parrot.app/Contents/MacOS/Parrot"),
            "a"*64,"b"*40,state_path=self.state,verify=lambda:dict(self.identity),
            phase=self.phase,boot_id=lambda:"fixture-boot",**kwargs)
    def read(self):
        return json.loads(self.state.read_text()) if self.state.exists() else {}
    def test_three_phases_same_nonce_complete(self):
        result=self.runner().run()
        self.assertEqual(result.get("status"),"complete")
        self.assertTrue(result.get("persistence_observed"))
        self.assertEqual([p for p,n in self.calls],["write","verify-cleanup","absent"])
        self.assertEqual(len({n for p,n in self.calls}),1)
        self.assertEqual(self.state.stat().st_mode&0o777,0o600)
    def test_failed_phase_retains_nonce_and_no_replacement(self):
        self.fail_phase="verify-cleanup"
        result=self.runner().run()
        self.assertEqual(result.get("status"),"pending")
        nonce=self.read().get("nonce");count=len(self.calls)
        self.assertIsNotNone(nonce)
        second=self.runner().run()
        self.assertEqual(second.get("status"),"pending")
        self.assertEqual(len(self.calls),count)
        self.assertEqual(self.read().get("nonce"),nonce)
    def test_recovery_is_cleanup_only_same_nonce(self):
        self.fail_phase="verify-cleanup";self.runner().run()
        nonce=self.read().get("nonce");self.fail_phase=None;self.calls=[]
        result=self.runner().run(recover=True)
        self.assertEqual(result.get("status"),"recovered")
        self.assertFalse(result.get("persistence_observed",True))
        self.assertEqual(self.calls,[("verify-cleanup",nonce),("absent",nonce)])
    def test_definitive_collision_is_terminal_and_never_cleaned(self):
        for status in (0,-25299):
            with self.subTest(status=status):
                self.state.unlink(missing_ok=True);self.calls=[]
                runner=self.runner();phase=runner.phase
                def collision(name,nonce,process):
                    result=phase(name,nonce,process)
                    result["report"].update(stage="collision",status=status)
                    result["exit_code"]=1
                    return result
                runner.phase=collision
                result=runner.run()
                self.assertEqual(result.get("status"),"refused")
                self.assertFalse(result.get("persistence_observed",True))
                before=list(self.calls)
                with self.assertRaises(module.ProbeFailure):self.runner().run(recover=True)
                self.assertEqual(self.calls,before)
                self.assertEqual([p for p,n in self.calls],["write"])
    def test_directory_sync_failure_prevents_all_native_phases(self):
        def sync(path):
            if Path(path)==self.state.parent:raise OSError("fixture journal directory sync failure")
        with mock.patch.object(module,"sync_directory",side_effect=sync,create=True):
            with self.assertRaises(OSError):self.runner().run()
        self.assertEqual(self.calls,[])
    def test_each_phase_has_a_synced_pending_nonce_checkpoint(self):
        synced=[];real_sync=module.sync_directory
        def sync(path):
            real_sync(path)
            if Path(path)==self.state.parent and self.state.exists():synced.append(self.read())
        runner=self.runner();phase=runner.phase
        def checked(name,nonce,process):
            self.assertTrue(synced)
            self.assertEqual(synced[-1].get("current_phase"),name)
            self.assertEqual(synced[-1].get("nonce"),nonce)
            self.assertIsNone(synced[-1].get("current_pid"))
            return phase(name,nonce,process)
        runner.phase=checked
        with mock.patch.object(module,"sync_directory",side_effect=sync):
            self.assertEqual(runner.run().get("status"),"complete")
    def test_missing_ancestor_links_synced_before_phase(self):
        base=Path(self.temp.name);self.state=base/"new-a/new-b/state.json"
        events=[];real_sync=module.sync_directory
        def sync(path):
            real_sync(path);events.append(("sync",Path(path)))
        runner=self.runner();phase=runner.phase
        def tracked(name,nonce,process):
            events.append(("phase",name));return phase(name,nonce,process)
        runner.phase=tracked
        with mock.patch.object(module,"sync_directory",side_effect=sync):
            self.assertEqual(runner.run().get("status"),"complete")
        first=next(i for i,event in enumerate(events) if event[0]=="phase")
        self.assertIn(("sync",base),events[:first])
        self.assertIn(("sync",base/"new-a"),events[:first])
    def test_wrong_nonce_cannot_pass(self):
        self.change=lambda phase,result:result.update(nonce="wrong") if phase=="write" else None
        self.assertEqual(self.runner().run().get("status"),"pending")
        self.assertEqual(len(self.calls),1)
    def test_report_pid_must_match_real_process(self):
        self.change=lambda phase,result:result.update(pid=1) if phase=="write" else None
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_authentication_ui_flag_cannot_be_ignored(self):
        self.change=lambda phase,result:result.update(userInteractionDisallowed=False)
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_cleanup_requires_real_not_found(self):
        self.change=lambda phase,result:result.update(status=0) if phase=="absent" else None
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_cleanup_flag_required(self):
        self.change=lambda phase,result:result.update(cleanupVerified=False) if phase=="absent" else None
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_extra_report_data_refused(self):
        self.change=lambda phase,result:result.update(value="public-unexpected")
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_foreign_state_never_overwritten(self):
        self.state.write_text('{"foreign":"retain"}')
        with self.assertRaises(module.ProbeFailure): self.runner().run()
        self.assertEqual(self.read(),{"foreign":"retain"})
    def test_scope_must_match_component(self):
        self.change=lambda phase,result:result.update(scope="other-component")
        self.assertEqual(self.runner().run().get("status"),"pending")
    def test_unknown_stage_text_is_never_recorded(self):
        sentinel="public-sentinel-that-must-not-be-logged"
        self.change=lambda phase,result:result.update(stage=sentinel)
        result=self.runner().run()
        self.assertEqual(result.get("status"),"pending")
        self.assertNotIn(sentinel,json.dumps(self.read()))
    def test_foreign_json_type_refused_safely(self):
        self.state.write_text('[1,2]');self.state.chmod(0o600)
        with self.assertRaises(module.ProbeFailure):self.runner().run()
    def test_artifact_change_holds_pending_cleanup(self):
        self.fail_phase="verify-cleanup";self.runner().run();nonce=self.read().get("nonce")
        self.identity["binary_sha256"]="d"*64
        with self.assertRaises(module.ProbeFailure):self.runner().run(recover=True)
        self.assertEqual(self.read().get("nonce"),nonce)
    def native_fixture(self,body):
        executable=Path(self.temp.name)/"fixture-process"
        executable.write_text("#!"+sys.executable+"\n"+body+"\n");executable.chmod(0o700)
        runner=self.runner();runner.binary=executable
        return runner
    def test_native_boundary_reaps_child_and_preserves_pid(self):
        runner=self.native_fixture('import json,os;print(json.dumps({"pid":os.getpid()}))')
        events=[];result=runner._native_phase("write","PUBLIC-NONCE",lambda *v:events.append(v))
        self.assertEqual(result["pid"],result["report"]["pid"])
        self.assertEqual(events,[(result["pid"],False),(result["pid"],True)])
        self.assertEqual(result["exit_code"],0)
    def test_native_boundary_limits_output(self):
        runner=self.native_fixture('print("x"*10000)')
        events=[]
        with self.assertRaisesRegex(module.ProbeFailure,"phase_output_limit"):
            runner._native_phase("write","PUBLIC-NONCE",lambda *v:events.append(v))
        self.assertTrue(events[-1][1])
    def test_native_boundary_refuses_invalid_json(self):
        runner=self.native_fixture('print("not-json")')
        with self.assertRaisesRegex(module.ProbeFailure,"phase_json"):
            runner._native_phase("write","PUBLIC-NONCE",lambda *v:None)
    def test_native_boundary_times_out_and_reaps_child(self):
        runner=self.native_fixture('import time;time.sleep(12)')
        events=[]
        with self.assertRaisesRegex(module.ProbeFailure,"phase_timeout"):
            runner._native_phase("write","PUBLIC-NONCE",lambda *v:events.append(v))
        self.assertTrue(events[-1][1])
        with self.assertRaises(ProcessLookupError):os.kill(events[-1][0],0)
if __name__=="__main__":
    unittest.main()

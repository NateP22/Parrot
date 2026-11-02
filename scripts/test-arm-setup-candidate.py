#!/usr/bin/env python3
"""Synthetic build-only policy regressions; no code signing, app or credentials."""
import importlib.util,json,plistlib,tempfile,unittest
from pathlib import Path
P=Path(__file__).with_name("prepare-arm-setup-candidate.py")
spec=importlib.util.spec_from_file_location("arm_setup",P)
module=importlib.util.module_from_spec(spec)
try:spec.loader.exec_module(module)
except FileNotFoundError:module=None
SOURCE="a"*40
def base():return dict(CFBundleIdentifier="com.uygar.parrot",CFBundleName="Parrot",CFBundleExecutable="Parrot",LSMinimumSystemVersion="14.0")
BUILD={"platform":"MACOS","minos":"14.0","sdk":"26.5"}
class BuildOnlyPolicy(unittest.TestCase):
 def setUp(self):self.assertIsNotNone(module,"build-only policy not implemented")
 def info(self,**kw):
  args=dict(base=base(),source=SOURCE,host="x86_64",archs=["arm64"],build=BUILD);args.update(kw)
  return module.prepare_info(**args)
 def test_exact_own_qa_policy_and_no_original_mutation(self):
  value=base();before=dict(value);result=self.info(base=value)
  self.assertEqual(value,before)
  self.assertEqual(result["CFBundleIdentifier"],"com.uygar.parrot.sat54.qa")
  self.assertEqual(result["ParrotKeychainService"],result["CFBundleIdentifier"])
  self.assertEqual(result["CFBundleName"],"Parrot SAT54 QA")
  self.assertEqual(result["CFBundleDisplayName"],"Parrot SAT54 QA")
  for key in ("ParrotQASetupByDefault","ParrotNativeAnswerTrace"):self.assertIs(result[key],True)
  for key in ("ParrotSessionOnlyCredentials","SUEnableAutomaticChecks","SUAutomaticallyUpdate"):self.assertIs(result[key],False)
  self.assertNotIn("SUFeedURL",result)
  self.assertEqual(type(result["ParrotQACredentialProbeVersion"]),int)
  self.assertEqual(result["ParrotQACredentialProbeVersion"],1)
  self.assertEqual(result["ParrotSourceCommit"],SOURCE)
  self.assertEqual(result["ParrotBuildArchitecture"],"arm64")
  self.assertEqual(result["ParrotBuildHostArchitecture"],"x86_64")
 def test_wrong_base_identity_or_executable_rejected(self):
  for key,bad in (("CFBundleIdentifier","foreign.app"),("CFBundleExecutable","Other"),("CFBundleName","Other"),("LSMinimumSystemVersion","13.0")):
   value=base();value[key]=bad
   with self.subTest(key=key),self.assertRaises(ValueError):self.info(base=value)
 def test_source_host_target_build_boundaries(self):
  for kwargs in ({"source":"bad"},{"source":"A"*40},{"host":"arm64"},{"archs":["x86_64"]},{"archs":["arm64","x86_64"]},{"build":dict(BUILD,minos="13.0")},{"build":dict(BUILD,sdk="26.2")},{"build":dict(BUILD,platform="IOS")}):
   with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):self.info(**kwargs)
 def test_original_update_settings_removed(self):
  value=base();value.update(SUFeedURL="https://invalid.example/feed",SUAutomaticallyUpdate=True,ParrotKeychainService="com.uygar.parrot")
  result=self.info(base=value)
  self.assertNotIn("SUFeedURL",result);self.assertIs(result["SUAutomaticallyUpdate"],False)
  self.assertEqual(result["ParrotKeychainService"],"com.uygar.parrot.sat54.qa")
 def test_both_full_profiles_and_all_arm_execution_pending(self):
  value=module.pending()
  self.assertEqual(value["status"],"BUILD_ONLY_SETUP_FULL_PROFILES_PENDING")
  self.assertIs(value["native_acceptance"],False)
  self.assertEqual(value["host_checks"],{"full_profile":"pending"})
  self.assertEqual(set(value["arm_checks"]),{"full_profile","query_startup","setup_model_owners","synthetic_credentials","window_lifecycle","real_provider","system_audio","final_qualification"})
  self.assertEqual(set(value["arm_checks"].values()),{"pending"})
 def test_wrapper_refuses_local_execution_before_build_work(self):
  import os,subprocess
  env=dict(os.environ);env.pop("GITHUB_ACTIONS",None)
  result=subprocess.run(["/bin/bash",str(P.with_name("build-arm-setup-candidate.sh"))],env=env,capture_output=True,text=True,timeout=5)
  self.assertEqual(result.returncode,2);self.assertIn("CI-only",result.stderr)
 def focused(self,root):
  (root/"focused-passed.txt").write_text("\n".join(module.FOCUSED)+"\n")
  for name in module.FOCUSED:(root/(name+".log")).write_text("synthetic command succeeded\n")
 def test_focused_logs_are_complete_and_hashed(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);self.focused(root);result=module.focused_receipts(root)
   self.assertEqual(len(result),len(module.FOCUSED));self.assertGreaterEqual(len(result),9)
   self.assertTrue(all(len(row["sha256"])==64 and row["exit_code"]==0 for row in result))
 def test_missing_duplicate_or_empty_focused_log_rejected(self):
  for mode in ("missing","duplicate","empty"):
   with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp);self.focused(root)
    if mode=="missing":(root/"focused-passed.txt").write_text("")
    if mode=="duplicate":(root/"focused-passed.txt").write_text("\n".join(module.FOCUSED+[module.FOCUSED[0]]))
    if mode=="empty":(root/(module.FOCUSED[0]+".log")).write_text("")
    with self.assertRaises(ValueError):module.focused_receipts(root)
class ActualWorkspacePolicy(unittest.TestCase):
 def setUp(self):
  self.assertIsNotNone(module)
  from unittest.mock import patch
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.root=Path(self.temp.name);self.app=self.root/"dist/Parrot.app"
  for name in module.cross.CODE_MEMBERS:
   path=self.app/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(bytes.fromhex("cffaedfe")+b"synthetic-code")
  (self.app/"Contents/Info.plist").write_bytes(plistlib.dumps(base()))
  self.folder=self.root/"build-evidence";self.folder.mkdir()
  BuildOnlyPolicy.focused(self,self.folder)
  self.bad=None;self.ents={"com.apple.security.app-sandbox":True}
  self.p_env=patch.dict(module.os.environ,{"GITHUB_ACTIONS":"true","GITHUB_RUN_ID":"12345"})
  self.p_env.start();self.addCleanup(self.p_env.stop)
  self.p_run=patch.object(module.cross,"run",side_effect=self.command);self.p_run.start();self.addCleanup(self.p_run.stop)
 def command(self,args,cwd=None):
  args=[str(x) for x in args]
  if args==["/usr/bin/uname","-m"]:return "x86_64"
  if args==["/usr/bin/git","rev-parse","HEAD"]:return SOURCE
  if args==["/usr/bin/git","diff","HEAD","--exit-code"]:return ""
  if args[:2]==["/usr/bin/git","show"]:return plistlib.dumps(self.ents).decode()
  if args[:3]==["/usr/bin/xcrun","--sdk","macosx"]:return "26.5"
  if args[:3]==["/usr/bin/xcrun","vtool","-show-build"]:return "platform MACOS\nminos 14.0\nsdk 26.5"
  if args[:2]==["/usr/bin/lipo","-archs"]:
   return "x86_64" if self.bad=="nested" and args[-1]!=str(self.app/module.cross.CODE_MEMBERS[0]) else "arm64"
  if args[:2]==["/usr/bin/codesign","--verify"]:
   if self.bad=="signature":raise ValueError("codesign_failed")
   return ""
  if args[:3]==["/usr/bin/codesign","--display","--entitlements"]:
   value=dict(self.ents,**{"com.apple.security.cs.disable-library-validation":True})
   if self.bad=="entitlements":value["unexpected"]=True
   return plistlib.dumps(value).decode()
  if args[:3]==["/usr/bin/codesign","--display","--verbose=4"]:
   return "flags=0x2(adhoc)" if self.bad=="runtime" else "flags=0x10002(adhoc,runtime)"
  raise AssertionError("Unexpected external call: "+repr(args))
 def archive(self,wrong=False):
  import zipfile
  with zipfile.ZipFile(self.root/"Parrot-arm64-setup-only.zip","w") as z:
   for path in self.app.rglob("*"):
    if path.is_file():
     data=path.read_bytes()
     if wrong and path==self.app/module.cross.CODE_MEMBERS[0]:data=b"changed"
     z.writestr("Parrot.app/"+path.relative_to(self.app).as_posix(),data)
 def test_real_workspace_flow_keeps_every_execution_pending(self):
  module.prepare(self.root);self.archive();result=module.finalize(self.root)
  self.assertEqual(result["status"],"BUILD_ONLY_SETUP_FULL_PROFILES_PENDING")
  self.assertIs(result["native_acceptance"],False)
  self.assertEqual(len(result["macho_members"]),len(module.cross.CODE_MEMBERS))
  self.assertTrue(result["hardened_runtime"])
 def test_missing_ci_refuses_before_external_calls(self):
  module.os.environ.pop("GITHUB_ACTIONS",None)
  with self.assertRaisesRegex(ValueError,"ci_only"):module.prepare(self.root)
 def test_signature_runtime_entitlement_and_slice_rejections(self):
  for bad in ("signature","runtime","entitlements","nested"):
   with self.subTest(bad=bad):
    # Fresh prepare output per scenario, preserving the prior receipts.
    self.bad=None
    if (self.folder/"arm64-setup").exists():
     import shutil
     shutil.rmtree(self.folder/"arm64-setup")
     (self.app/"Contents/Info.plist").write_bytes(plistlib.dumps(base()))
    module.prepare(self.root);self.archive();self.bad=bad
    with self.assertRaises(ValueError):module.finalize(self.root)
 def test_changed_focused_log_rejected(self):
  module.prepare(self.root);self.archive()
  (self.folder/(module.FOCUSED[0]+".log")).write_text("changed")
  with self.assertRaisesRegex(ValueError,"prepared_changed"):module.finalize(self.root)
 def test_archive_byte_change_rejected(self):
  module.prepare(self.root);self.archive(wrong=True)
  with self.assertRaisesRegex(ValueError,"archive_bytes"):module.finalize(self.root)
if __name__=="__main__":unittest.main()

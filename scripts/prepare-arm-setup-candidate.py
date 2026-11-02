#!/usr/bin/env python3
"""Separate CI-only ARM setup artifact. BOTH full profiles remain pending."""
import copy,hashlib,importlib.util,json,os,plistlib,re,subprocess,sys,zipfile
from pathlib import Path
_spec=importlib.util.spec_from_file_location("cross_policy",Path(__file__).with_name("prepare-arm-cross-candidate.py"))
cross=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(cross)
QA="com.uygar.parrot.sat54.qa"
FOCUSED=["test-arm-setup-candidate.py","test-arm-cross-candidate.py","test-keychain-store.py",
 "test-qa-credential-admission.py","test-qa-window-reopen.py","test-native-credential-probe.py",
 "test-native-credential-runner.py","test-selector-credential-policy.py","test-qa-bundle-policy.py","test-native-answer-qualification.py",
 "test-microphone-input.sh"]
def prepare_info(base,source,host,archs,build):
 if not isinstance(base,dict) or any(base.get(k)!=v for k,v in {
  "CFBundleIdentifier":"com.uygar.parrot","CFBundleName":"Parrot","CFBundleExecutable":"Parrot"}.items()):
  raise ValueError("base_identity")
 if not isinstance(source,str) or not re.fullmatch("[a-f0-9]{40}",source):raise ValueError("source")
 if host!="x86_64" or archs!=["arm64"]:raise ValueError("architecture")
 if (cross.version(base.get("LSMinimumSystemVersion"))!=(14,0,0) or build.get("platform")!="MACOS"
  or cross.version(build.get("minos"))!=(14,0,0) or cross.version(build.get("sdk"))!=(26,5,0)):
  raise ValueError("build_version")
 result=copy.deepcopy(base)
 result.update(CFBundleIdentifier=QA,CFBundleName="Parrot SAT54 QA",CFBundleDisplayName="Parrot SAT54 QA",
  ParrotKeychainService=QA,ParrotSessionOnlyCredentials=False,ParrotNativeAnswerTrace=True,
  ParrotQASetupByDefault=True,ParrotQACredentialProbeVersion=1,SUEnableAutomaticChecks=False,
  SUAutomaticallyUpdate=False,ParrotSourceCommit=source,ParrotBuildArchitecture="arm64",
  ParrotBuildHostArchitecture="x86_64",ParrotARMExecutionStatus="pending",
  ParrotFullHostProfileStatus="pending",ParrotBuildOnlySetup=True)
 result.pop("SUFeedURL",None)
 return result
def pending():
 return dict(status="BUILD_ONLY_SETUP_FULL_PROFILES_PENDING",native_acceptance=False,
  host_checks={"full_profile":"pending"},arm_checks={key:"pending" for key in
  ("full_profile","query_startup","setup_model_owners","synthetic_credentials","window_lifecycle",
   "real_provider","system_audio","final_qualification")})
def focused_receipts(folder):
 try:
  names=cross.read_regular(folder/"focused-passed.txt",8192).decode().splitlines()
  if names!=FOCUSED:raise ValueError("focused_tests_incomplete")
  result=[]
  for name in names:
   path=folder/(name+".log");data=cross.read_regular(path,4*1024*1024)
   if not data.strip():raise ValueError("focused_log_empty")
   result.append(dict(name=name,exit_code=0,sha256=hashlib.sha256(data).hexdigest()))
  return result
 except (OSError,UnicodeError) as error:raise ValueError("focused_receipts") from error
def context(root):
 if os.environ.get("GITHUB_ACTIONS")!="true":raise ValueError("ci_only")
 root=Path(root).resolve()
 host=cross.run(["/usr/bin/uname","-m"])
 if host!="x86_64":raise ValueError("host_architecture")
 source=cross.run(["/usr/bin/git","rev-parse","HEAD"],cwd=root)
 cross.run(["/usr/bin/git","diff","HEAD","--exit-code"],cwd=root)
 if cross.run(["/usr/bin/xcrun","--sdk","macosx","--show-sdk-version"])!="26.5":raise ValueError("sdk")
 app=root/"dist/Parrot.app";binary=app/cross.CODE_MEMBERS[0]
 archs=cross.run(["/usr/bin/lipo","-archs",binary]).split()
 build_text=cross.run(["/usr/bin/xcrun","vtool","-show-build",binary])
 build=cross.parse_build_version(build_text)
 if archs!=["arm64"] or cross.version(build["minos"])!=(14,0,0) or cross.version(build["sdk"])!=(26,5,0):
  raise ValueError("target_build")
 folder=root/"build-evidence"
 tests=focused_receipts(folder)
 # Immutable commit blob, never a mutable checkout entitlement baseline.
 blob=cross.run(["/usr/bin/git","show",source+":Parrot/Parrot.entitlements"],cwd=root)
 ents=plistlib.loads(blob.encode());ents["com.apple.security.cs.disable-library-validation"]=True
 return root,app,folder,source,host,archs,build,build_text,tests,ents
def prepare(root):
 root,app,folder,source,host,archs,build,build_text,tests,ents=context(root)
 base_bytes=cross.read_regular(app/"Contents/Info.plist")
 info=prepare_info(plistlib.loads(base_bytes),source,host,archs,build)
 output=folder/"arm64-setup";output.mkdir(exist_ok=False)
 (output/"base-info.plist").write_bytes(base_bytes)
 encoded=plistlib.dumps(info);encoded_ents=plistlib.dumps(ents)
 (app/"Contents/Info.plist").write_bytes(encoded)
 (output/"test-info.plist").write_bytes(encoded)
 (output/"test-entitlements.plist").write_bytes(encoded_ents)
 (output/"macho-build.txt").write_text(build_text+"\n")
 result=dict(pending(),source_commit=source,host_architecture=host,target_architecture="arm64",
  build_version=build,info_sha256=hashlib.sha256(encoded).hexdigest(),
  entitlements_sha256=hashlib.sha256(encoded_ents).hexdigest(),focused_tests=tests)
 with (output/"PREPARED.json").open("x") as stream:json.dump(result,stream,indent=2);stream.write("\n")
 return result
def finalize(root):
 root,app,folder,source,host,archs,build,_,tests,ents=context(root)
 output=folder/"arm64-setup"
 prepared=json.loads(cross.read_regular(output/"PREPARED.json"))
 expected=prepare_info(plistlib.loads(cross.read_regular(output/"base-info.plist")),source,host,archs,build)
 info=cross.read_regular(app/"Contents/Info.plist")
 encoded_ents=cross.read_regular(output/"test-entitlements.plist")
 if (prepared.get("source_commit")!=source or prepared.get("focused_tests")!=tests
  or plistlib.loads(info)!=expected or plistlib.loads(encoded_ents)!=ents
  or hashlib.sha256(info).hexdigest()!=prepared.get("info_sha256")
  or hashlib.sha256(encoded_ents).hexdigest()!=prepared.get("entitlements_sha256")):
  raise ValueError("prepared_changed")
 cross.run(["/usr/bin/codesign","--verify","--deep","--strict",app])
 embedded=plistlib.loads(cross.run(["/usr/bin/codesign","--display","--entitlements",":-",app]).encode())
 if embedded!=ents:raise ValueError("embedded_entitlements")
 signature=cross.run(["/usr/bin/codesign","--display","--verbose=4",app])
 flags=re.search(r"\bflags=0x([a-fA-F0-9]+)\b",signature)
 if not flags or not int(flags.group(1),16)&0x10000:raise ValueError("hardened_runtime")
 members=[]
 for path in sorted(app.rglob("*")):
  if path.is_symlink():
   if not path.resolve().is_relative_to(app.resolve()):raise ValueError("symlink_escape")
   continue
  if not path.is_file():continue
  with path.open("rb") as stream:magic=stream.read(4)
  if magic not in cross.MACHO_MAGICS:continue
  slices=cross.run(["/usr/bin/lipo","-archs",path]).split()
  if "arm64" not in slices:raise ValueError("nested_arm")
  members.append(dict(path=path.relative_to(app).as_posix(),architectures=slices,sha256=cross.digest(path)))
 if not set(cross.CODE_MEMBERS).issubset({x["path"] for x in members}):raise ValueError("missing_code")
 archive_path=root/"Parrot-arm64-setup-only.zip"
 binary_sha=cross.digest(app/cross.CODE_MEMBERS[0]);info_sha=cross.digest(app/"Contents/Info.plist")
 with zipfile.ZipFile(archive_path) as archive:
  names=archive.namelist()
  if len(names)!=len(set(names)) or any(n.startswith("/") or ".." in n.split("/") or "\\\\" in n for n in names):
   raise ValueError("archive_paths")
  if archive.testzip() is not None:raise ValueError("archive_crc")
  for relative,sha in [(cross.CODE_MEMBERS[0],binary_sha),("Contents/Info.plist",info_sha)]:
   with archive.open("Parrot.app/"+relative) as stream:
    if cross.digest_stream(stream)!=sha:raise ValueError("archive_bytes")
 run_id=os.environ.get("GITHUB_RUN_ID","")
 if not re.fullmatch("[1-9][0-9]*",run_id):raise ValueError("run_id")
 result=dict(pending(),source_commit=source,run_id=int(run_id),host_architecture=host,
  target_architecture="arm64",build_version=build,focused_tests=tests,binary_sha256=binary_sha,
  info_sha256=info_sha,archive_sha256=cross.digest(archive_path),
  entitlements_sha256=hashlib.sha256(encoded_ents).hexdigest(),embedded_entitlements_verified=True,
  hardened_runtime=True,bundle_signature="deep_strict_verified",macho_members=members)
 with (output/"manifest.json").open("x") as stream:json.dump(result,stream,indent=2);stream.write("\n")
 return result
if __name__=="__main__":
 try:
  if sys.argv[1:] not in ([],["--finalize"]):raise ValueError("arguments")
  root=Path(__file__).resolve().parents[1]
  print(json.dumps(finalize(root) if sys.argv[1:] else prepare(root),sort_keys=True))
 except (OSError,ValueError,KeyError,subprocess.SubprocessError,zipfile.BadZipFile) as error:
  print("ARM setup candidate refused: "+str(error),file=sys.stderr);raise SystemExit(1)

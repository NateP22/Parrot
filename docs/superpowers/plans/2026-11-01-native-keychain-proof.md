# Native QA Keychain Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Prove real QA-only synthetic credential persistence across separate process launches and verify cleanup without touching provider accounts.

**Architecture:** A strict setup command dispatches before app/model/store construction. Three invocations use the existing production credential store and an uncached metadata query. The public runner verifies exited distinct processes and exact bounded reports; actual native proof stays distinct from mock regressions.

**Tech Stack:** Swift/Foundation/Security, existing SwiftPM app and CLI harness, Python3, existing Mac CI.

**Spec:** docs/superpowers/specs/2026-11-01-native-keychain-proof.md

## Global Constraints

- Exact supported QA bundle/service com.uygar.parrot.sat54.qa; persistent credentials; setup mode only.
- Original app/service, provider accounts, ACLs/protection/backend and normal interactive behavior remain unchanged.
- One local compiler/job at a time; no full local build. No private sources/questions/keys/audio/app data in public source or CI.
- Known fixture and canonical UUID account namespace only; no arbitrary account or value arguments.
- No authentication UI; refusal/unknown statuses are failure, never absence or success.
- This is Task2 component proof, never provider or final native acceptance.

## Review Focus

1. Existing UUID/account collision must abort before write and never overwrite.
2. Unavailable read or mismatching data must never lead to deletion.
3. Cached nil must not pass cleanup; a fresh process needs actual item-not-found.
4. Invalid identity/service/flags/arguments or session-only mode must make zero Keychain calls.
5. Legacy no-UI setting failure/timeouts must abort without opening authentication or changing normal app behavior.

### Task 1: Admit only the bounded command

Files: create Services/QACredentialProbePolicy.swift and scripts/test-qa-credential-admission.py; modify Services/QASetupLaunch.swift and its existing profile tests.

Interface: QACredentialProbePolicy.request(options:[String]) -> Request? validates exactly [--qa-setup,--qa-credential-probe,phase,canonicalUUID]; Phase is write, verify-cleanup or absent. Request derives account and public fixture. Existing AnswerTraceRecorder.isAllowed plus runtime service/persistent/setup checks remain mandatory.

- [x] Add a focused compiled admission test; valid command must be settingsOnly, bad UUID/phase/extra arguments/production identity/false or string flag must be rejected. Run against unchanged QASetupLaunch and preserve expected valid-command RED.
- [x] Implement minimal shared parser/admission, run focused GREEN, extend existing full harness cases.

### Task 2: Real credential operations and no-UI probe

Files: modify Services/AnalysisProvider.swift; create QACredentialProbe.swift; modify ParrotApp.swift, scripts/credential-regression.swift and scripts/test-keychain-store.py; create scripts/test-native-credential-probe.py for hermetic probe logic.

Interfaces: APIKeyStore.metadataStatus(account:String)->OSStatus is uncached/attributes-only and rejects unavailable service/session mode; @discardableResult delete(account:)->Bool reports actual success/not-found. Normal save/load query and cache defaults are preserved. Probe-only allowInteraction=false adds a fresh LAContext with interactionNotAllowed=true to every item query/add. Atomic replaceExisting=false save refuses concurrent collisions without Update. QACredentialProbe.run() validates exact bundle/typed QA flag/service/persistent/setup state before dispatch; execute(request:) returns a bounded Codable report with stage/status/PID/nonce, never value.

- [x] Add tests for metadata cache bypass, not-found versus denied/unavailable and delete failures; run RED before altering production methods.
- [x] Add tests for UI-disallow/set/get failure, collision, wrong fixture, delete failure and missing-versus-unavailable cleanup with every Security API shadowed. nm must prove no real Security item or interaction calls are linked before test execution.
- [x] Implement minimal methods and probe, dispatch before normal app construction; set/read back process-only legacy Keychain UI refusal before item operations, and apply the per-query noninteractive context. Explicitly encode a nil status as null; actual Swift JSON must pass the real Python validator. Add an8s internal timeout. Never reset an unknown account.
- [x] Run focused GREEN and all existing credential regressions. Compare default production calls/queries/cache behavior to baseline; no unpinned dependencies.

### Task 3: Native three-process evidence

Files: create scripts/run-native-credential-probe.py; modify scripts/build-local-candidate.sh and FILEMAP.md.

Interface: runner takes an exact QA app binary path plus required expected binary SHA256 and source commit, verifies version1 bundle metadata and deep strict signature/source identity, generates UUID, then starts write→verify-cleanup→absent sequentially with10s per-process limit. Accept only correct stage/nonce, distinct exited PIDs and zero exit codes. Report status without fixture values. An exclusive0600 durable journal/lock preserves nonce and sanitized stage. Pending runs refuse a replacement; --recover only verifies/cleans that same artifact/nonce and never proves persistence. Bounded stdout/stderr,10s deadline and owned-child reap are tested with real fictional subprocesses.

- [x] Test runner ordering, timeout/failed status/extra output/nonce mismatch/PID reuse rejection before implementation; these do not claim native Keychain proof.
- [ ] Run native phases from the actual signed CI QA bundle after existing full make test/build/signature checks. Read source/artifact hashes and logs; keep only source and fictional fixture in CI.
- [ ] Independent patch review, commit/push to existing authorized fork branch and run existing Mac workflow sequentially. Do not install until immutable artifact and source review pass.
- [ ] Use verified isolated backup/update route on this Mac; run the exact same signed installed binary in three processes and verify cleanup/status/no prompt. Source/native component critic before recording this component complete. Task3 real authentication and final full-goal acceptance remain open.


## Current checkpoint

Admission RED8 to GREEN0; metadata/delete API compile RED to GREEN78; atomic collision behavioral RED8 to GREEN92; phase behavioral RED26 to GREEN41; runner corrected-fixture RED11 to GREEN18; actual Swift report contract RED2 to GREEN3; no-UI query behavioral RED1 to GREEN. These are hermetic/component results only. Full Mac build, actual signed Security calls and local-native component critic remain pending. No real provider or answer acceptance.

Initial independent source critic HOLD found two recovery defects. Preserve atomic-add status through APIKeyStore.createIfAbsent; a definitive metadata/racing duplicate becomes terminal refusal and cannot enter cleanup. Unknown writes still retain pending nonce. Sync journal/history data and parent directory before starting any native phase; sync failure must prevent launch. Regressions reproduced atomic duplicate misclassification, two cross-run collision paths and missing directory-sync refusal before fixing them. Same-critic final review is required.

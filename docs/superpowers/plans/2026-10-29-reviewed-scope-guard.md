# Reviewed Scope Guard Implementation Plan

> For agentic workers: execute inline with TDD and one independent branch review; preserve the existing repair checkout and prior test app.

Goal: prevent a related signed fact from crossing the reviewed question-scope and source-authority boundary.
Architecture: required typed v2 source authority; signed per-answer scope and supported forms; local unique-scope requirement checked before candidate projection and after model selection.
Tech stack: Swift/Foundation/CryptoKit, existing CLI profile harness and synthetic signed fixtures.
Spec: ../specs/2026-10-29-reviewed-scope-guard-design.md

Global constraints: whole replies only;1–2sentences/max30words; source hashes/exact UTF-8 evidence/version/privacy unchanged; no silent v1 migration or free-generation fallback; no private fixture/key upload. Source and component proof never replace full real/unseen/native critic acceptance.

Review focus: same-provider wrong scope; compound forms; quoted/negated scope bait; source/scope metadata tampering; v1 saved-library reopen.

- [x] Add signed synthetic v2 scope fixtures and tests in Parrot/ProfileTest+ReviewedScope.swift and extend existing catalog/store transport tests. Run against unchanged source: expected FAIL for unsupported v2 and the previously reproduced acceptance-boundary failure.
- [x] Implement ReviewedQuestionScope.swift (SourceAuthority, ScopeDefinition, QuestionForm, QuestionRequirement), v2 identity/validation and Snapshot.questionRequirement/permitsAnswer in ReviewedAnswerCatalog.swift. Required groups use AND/OR whole-word matching; every recognized form must be supported. Add candidate-path and forced-ID tests.
- [x] Recompute canonical eligibility in AnalysisProvider.reviewedAnswerDraft; include scope/authority in the redacted selection projection. Preserve original local question identity and evidence. Update catalog-sign envelope and synthetic fixtures; verify strict persistence cannot reopen v1 into generation.
- [ ] Run focused actual-source catalog/provider/privacy/store checks; run full make test on the supported Mac CI toolchain. Independently review the full patch and fix material findings with regression tests.
- [x] Preserve a live profile's ID and general-knowledge policy across asynchronous retrieval/provider/dedup work. Revalidate policy and catalog before delivery; defer resolution, mood/coaching, identity insertion and callbacks until the final fence. Gated actual-engine regressions must reject stale replies and requeue the question under the current policy, with unchanged-profile controls.
- [ ] Verify exact built artifact; re-review/migrate private source scopes, sign/import normally and repeat all original plus unseen cases and actual native timing/citation/report/save-reopen gates before any completion claim.

Ledger: baseline31c4273. Existing private production-boundary regression has3FAIL/1positive; no source or native success is inferred from this plan. User already authorized isolated repair/testing and inline work; no further workflow question is needed.

Focused verification:94catalog/scope,79provider/privacy/actualKBservice/store and21actual-engine policy checks pass. Engine local proof uses plain reference-model adapters; full MacCI must exercise the real SwiftData models. Temporal/advice state regressions and provider/Jev/error policy-switch regressions were observed failing before repair. All real-source migration and native acceptance gates remain open.

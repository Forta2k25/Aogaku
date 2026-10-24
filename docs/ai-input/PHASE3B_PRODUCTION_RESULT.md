# Phase 3b production runtime-DB correction — COMPLETE WITH DEFERRED INTEGRATION TESTS

Date: 2026-10-07 JST. Production `forta-aogaku` / `505828754933`; bucket `forta-aogaku.firebasestorage.app`; Release Bundle ID `com.forta2k25.Aogaku`.

**Phase 3b is complete with the three explicitly deferred new-AI integration tests. Phase 3b-origin Phase 4 blockers: zero. Phase 4 was not authorized or executed.**

## Correction and exact artifact tests

`aiDatabaseId()` uses the fixed named database `aogaku-ai` only when `process.env.AI_FIRESTORE_DATABASE_ID` is undefined. It does not depend on Firebase CLI injecting a parameter default, does not set environment variables, and never falls back to `(default)`. A present empty/default/other value still throws `AI_DATABASE_MISMATCH`.

| Runtime environment | Exact SDK-only production artifact result |
|---|---|
| variable undefined | PASS: aogaku-ai |
| aogaku-ai | PASS: aogaku-ai |
| empty string | correctly rejected: AI_DATABASE_MISMATCH |
| (default) | correctly rejected: AI_DATABASE_MISMATCH |
| other-db | correctly rejected: AI_DATABASE_MISMATCH |

Fresh current Node22 metadata and actual SourceCodeGet ZIPs were captured as the new baseline. No old approval, metadata baseline or signed upload URL was reused. A new approval binds fresh source, baseline, wrapper and artifact hashes. The eight-file artifact changes only `lib/ai/databases.js`; all other seven source/package files match each current installed source byte-for-byte. SDK dependencies, recovered legacy deletion contracts and existing profiles are unchanged.

## Three sequential installed updates

Each update obtained a fresh upload URL, used only the required Gen1/Gen2 headers, confirmed staging before PATCH, waited for operation completion, compared the installed full manifest with the new artifact and verified protected state before proceeding to the next Function. Final SourceCodeGet verification was repeated after all E2E and prior-fixture cleanup.

| Function | Before full source manifest SHA256 | After full source manifest SHA256 | Actual updateTime |
|---|---|---|---|
| preDeleteCleanup | `2304cabbe6917c0f42baf91784488c466e86df570ff23a5679070546151631c5` | `d44148dbddb59e660524af5451ad8ed6d6123d39e5e28e04df3a1f6feea71a5f` | `2026-10-07T00:29:41.948897279Z` |
| deleteAccountServerSide | `2304cabbe6917c0f42baf91784488c466e86df570ff23a5679070546151631c5` | `d44148dbddb59e660524af5451ad8ed6d6123d39e5e28e04df3a1f6feea71a5f` | `2026-10-07T00:32:16.181674513Z` |
| onAuthUserDelete | `2304cabbe6917c0f42baf91784488c466e86df570ff23a5679070546151631c5` | `d44148dbddb59e660524af5451ad8ed6d6123d39e5e28e04df3a1f6feea71a5f` | `2026-10-07T00:34:35.657Z` |

- preDeleteCleanup: Gen2 / Node22 / asia-northeast1 / Callable HTTPS; `505828754933-compute@developer.gserviceaccount.com`; 1GiB, CPU 1, 540s, max 20; existing IMPORT_API_KEY version 2 binding preserved.
- deleteAccountServerSide: same Gen2/runtime/region/SA/settings/Secret profile.
- onAuthUserDelete: Gen1 / Node22 / asia-northeast1 / Auth user.delete; `forta-aogaku@appspot.gserviceaccount.com`; 256MB, 540s, max 3000; no Secret binding. All settings, including the already-extended timeout, are unchanged from the fresh Node22 baseline.

No runtime SA replacement, IAM change, Secret change, generation migration, Function deletion, full Functions deployment, --force, Rules/index/lifecycle change, queue resume or Scheduler resume occurred.

## Fresh production deletion E2E

All three independent disposable-UID routes PASS:

| Route | Result |
|---|---|
| preDeleteCleanup | PASS; Auth still present until explicit test deletion; repeated Callable cleanup succeeds, then actual Auth trigger cleanup succeeds |
| deleteAccountServerSide | PASS; actual Auth removed, complete cleanup including follow-up Auth trigger |
| onAuthUserDelete | PASS; independent Auth deletion invokes the installed Gen1 callback |

Each route verified named owner/default deletion fences, minimal source tombstones, jobs/runs/chunks/usage/periods/memberships and local-offering lectures cleanup, active raw/derived Storage removal, actual Cloud Tasks cancellation, missing run/parent and orphan objects, legacy quota/counter deletion, all three legacy AI callables rejecting the deleted/deleting UID, no quota recreation and preservation of the control synthetic UID. The first route includes 101 missing-parent memberships to force continuation beyond one batch. Four fresh synthetic accounts including the control were deleted; real users used: zero.

Production idempotence is directly verified by repeating preDeleteCleanup before Auth removal and by invoking the Auth trigger after completed preDelete/server-side cleanup. This is not a claim that retrying deleteAccountServerSide with an already-deleted Auth UID must return HTTP 200; its legacy top-level Auth error contract was not changed. Emulator regression also covers resumable helpers and repeated callbacks. In-flight provider failure/reserve/refund races are covered with provider mocks in Emulator; no live provider request or Secret payload access was needed to prove production fence rejection.

Legacy ASR checks object existence before quota. Its post-cleanup rejection test uses a tiny, synthetic legacy-path quota probe, explicitly deleted by the harness with an exact generation precondition. That probe is not proof of the not-yet-installed new-AI Storage finalize trigger.

## Previous stopped fixtures

The archived previous run and UID registry were preserved. Cleanup could run only after all fresh production deletion E2E routes passed against the corrected artifact. Before the first mutation it checked production identity, current Function updateTimes/runtime, the two registered Auth identities/run/creation times, every existing registered document testRunId, exact Storage names/digests/creation times and Tasks names/target/synthetic body.

The first ownership guard attempt stopped before any Auth/data mutation because Firebase canonicalized the preDeleteCleanup role in the fixture email to lowercase. Read-only comparison confirmed the exact expected canonical identity and matching UID/run/creation time. The zero-mutation stopped proof was archived; the guard was corrected to compare the exact generated lowercase email and all ownership checks were freshly repeated. No authorization or UID scope was broadened.

Both previous synthetic Auth accounts were then deleted individually through the corrected Gen1 Auth trigger. All old registered active contents were removed: 117 named fixture documents reduced to only three minimal source tombstones plus the owner marker; six existing default fixture documents were removed, retaining the new default fence; all 12 active Storage objects and three Tasks removed. All registered nested paths, missing-parent memberships, legacy quota and usage periods were checked absent, and Auth lookup confirmed both UIDs absent. The cleanup operator issued no manual Firestore/Storage/Tasks deletes; data cleanup was performed by the installed deletion handler.

Source/owner/default-fence minimal tombstones remain intentionally for receipt and resurrection protection. Existing bucket 7-day soft-delete retention is unchanged; active-object removal is not permanent purge of retained versions.

## Final protected-state and installed gates

PASS after all tests and old-fixture cleanup:

- Other 10 Functions' inventory, updateTimes and metadata unchanged. Old AI3 installed full manifests also still match the Phase 3a artifact.
- Default and named database configurations/Rules unchanged; default four composite indexes/eight fieldOverrides and named indexes unchanged.
- Project/resource IAM, runtime SAs, user-managed SA keys, API inventory, Secret metadata/versions/bindings, Storage lifecycle/soft-delete unchanged.
- Queue aiProcessSource in asia-northeast1 remains PAUSED; Scheduler/Eventarc inventory unchanged.
- Read-only installed verification now recognizes the actual slim deletion artifact rather than demanding deployment of the generic six-handler package. The quota installation receipt is retained and independently reverified.
- No signed upload/download URL, token, credential, Auth password or Secret payload is included in the new saved metadata/report.

## Tests and remaining boundary

TypeScript build PASS; domain 13/13 PASS; exact artifact DB environment cases 5/5 PASS; Emulator/legacy AI/quota/friend/Rules/database separation/deletion/refund/late-job regression 50/50 PASS, zero skips; deployment/ownership/installed-verifier safety tests 18/18 PASS; offline production target/config/preservation/allowlist guard PASS; production three-route E2E PASS; previous two-UID cleanup PASS.

Phase 3b blockers are zero. Mandatory deferred Phase 4/5 tests remain:

1. New AI admission while deletion is in progress.
2. Delayed new AI worker rejection.
3. Storage finalize removal of delayed new AI uploads.

No absent endpoint/404 is treated as security proof. New AI endpoints have not been deployed; sharing remains OFF. Phase 4 still needs separate human approval and fresh closed-profile artifact/preflight (empty allowedUIDs, sharing OFF, queue/Scheduler PAUSED and allowlist/trigger/IAM/target checks). This result does not authorize Phase 4, general release or App Store publication.

## Local files changed this correction turn

- functions/src/ai/databases.ts: undefined-only fixed named DB resolution; reject explicit invalid IDs.
- functions/test/rollout-artifacts.test.cjs: exact slim artifact without env injection; real Emulator deletion, named/default boundary and idempotence.
- scripts/test_phase3b_database_runtime.cjs: five exact production-artifact environment cases.
- scripts/prepare_phase3b.py: fresh Node22 installed-source baseline, fresh deployed dependency lock, reject any source change except databases.js.
- scripts/deploy_production_phase3b.cjs: fresh current Node22 capture/approval and exact runtime/environment regression gates; generation-specific staging headers preserved.
- scripts/production_phase3b_e2e.cjs: artifact-bound E2E evidence and explicit preDelete idempotent retry.
- scripts/cleanup_phase3b_stopped_fixtures.cjs: narrowly guarded old fixture ownership and two-UID cleanup via verified Auth trigger.
- scripts/test_phase3b_e2e_safety.cjs: unrelated fixture rejection, canonical email and installed-mode guards.
- scripts/verify_legacy_install.cjs: read-only slim deletion installed gate requiring production E2E and old fixture cleanup PASS.
- scripts/production_cloud.cjs: redact environment values/signed URLs when saving legacy metadata.
- docs/ai-input/PHASE3B_PRODUCTION_RESULT.md: this final result; private receipts/logs/artifacts under ignored build/production-phase3b/.

Earlier AI source, Dev evidence and stopped-run archives remain preserved. No commit, GitHub push, main/PR merge, App Store release or Aogaku-clean modification was performed.

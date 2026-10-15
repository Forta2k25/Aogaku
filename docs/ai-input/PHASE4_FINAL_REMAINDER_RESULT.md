# Phase 4 final remainder attempt - READ TIMEOUT / STOPPED SAFE

Report time: 2026-10-07T02:41:55.492826+00:00

Phase4 is incomplete. This attempt made ZERO production mutations. Fresh current23 metadata/source/IAM capture and preflight passed. Before the worker Function-scoped IAM addition, the next read-only snapshot timed out. No mutation had been attempted. The wrapper stopped without retries; read-only stopped-state metadata/source/private audits subsequently passed.

The observed error was `The operation was aborted due to timeout`, NOT a confirmed HTTP503/UNAVAILABLE. No response code or exact failing read endpoint was captured. No root cause is established. The error occurred before workeriam-before.json was saved, during the pre-mutation snapshot. Do not label it a confirmed503 or claim any IAM write succeeded this attempt.

## Fresh target / artifact / approval

Verified project forta-aogaku, number505828754933, bucket forta-aogaku.firebasestorage.app / US-CENTRAL1, Release bundle com.forta2k25.Aogaku. Named DB aogaku-ai remains Native / asia-northeast1 / delete protection ON, full client deny Rules, required indexes READY. Default/named database separation preserved.

All23 Functions metadata, full installed source manifests, updateTimes and IAM were freshly retrieved. All10 installed AI sources equal the approved closed nine-file manifest:

`34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`

New independent build/production-phase4-final/ holds fresh23 baseline/approval/source checks. Old approval/uploadURL/stopped baseline were not reused. Original source manifests were used only to verify immutable code. Source ZIP excludes env/plist/credentials/fixtures/tests/Secret values. Existing10 were excluded from CREATE/UPDATE; worker Run IAM SET is forbidden by this remainder guard.

## Twelve Functions

| Function | State | Trigger | updateTime |
|---|---|---|---|
| aiCreateSource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:05:42.041243896Z |
| aiCompleteSource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:09:13.057734690Z |
| aiGetSource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:12:01.146639576Z |
| aiListSources | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:14:54.199119370Z |
| aiGetEvidence | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:44:09.072151942Z |
| aiRetrySource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:47:59.794532874Z |
| aiUpdateSource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:50:58.826030128Z |
| aiDeleteSource | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:54:09.740232344Z |
| aiRetrieveContext | ACTIVE / unchanged / source PASS | Callable HTTPS | 2026-10-07T01:57:13.950479792Z |
| aiProcessSource | ACTIVE / unchanged / source PASS | TaskQueue HTTPS | 2026-10-07T02:00:13.221571590Z |
| aiReconcileInputs | NOT CREATED | Scheduler HTTPS | - |
| aiRejectLateUpload | NOT CREATED | Storage/Eventarc | - |

All10 installed AI: Gen2 / Node22 / asia-northeast1, runtime SA aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com, explicit DB aogaku-ai, allowedUIDs=[], sharing false / production hard OFF. Nine Callables: 256Mi/CPU0.1666/120s/min0max10/concurrency1. Worker: 2Gi/CPU1/1800s/min0max3/concurrency1.

## Worker IAM / Scheduler / Eventarc

- Actual worker Run projects/forta-aogaku/locations/asia-northeast1/services/aiprocesssource retains runtime SA roles/run.invoker. Fresh GET confirms it; no duplicate addition, policy or etag change this attempt.
- Function-scoped projects/forta-aogaku/roles/aogakuAIFunctionMetadata is still absent. No SET attempted. Project-wide expansion prohibited.
- Scheduler and AI Eventarc/Storage trigger remain absent; no create, pause/resume or execution this attempt. Scheduler PAUSED and Eventarc filter/destination checks remain pending.
- Queue projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource remains PAUSED; rate/retry/IAM unchanged.

## Stop audits / tests

- Fresh read-only metadata/IAM audit: PASS, all23 Function metadata/updateTimes, all existing IAM and protected state equal fresh baseline.
- Fresh full SourceCodeGet audit: all23 PASS. Thirteen legacy Functions and ten existing AI Functions unchanged.
- Ten AI private Run IAM policies contain no allUsers/allAuthenticatedUsers; IAM checks not disabled.
- Twenty anonymous POST probes across Run/cloudfunctions.net: ALL403. No nonexistent endpoint/404 counted as PASS. Valid production/Dev user tokens not acquired/probed; no Auth fixture or UID activation. IAM private boundary verified structurally and anonymously.
- Named/default DB metadata, Rules, indexes/fieldOverrides, Storage Rules, Secret metadata/versions/bindings, lifecycle/soft delete, API/SA inventories and zero user-managed SA keys unchanged. No Secret payload read, user-data write/delete or normal AI/provider processing.
- TypeScript build PASS; domain13/13 PASS; Emulator50/50 PASS with no fail/skip; exact closed/deploy/remainder guard11/11 PASS; production/named/rollout safety23/23 PASS.

## Remaining blockers

Phase4 fully successful: NO. Phase5 blockers zero: NO.

1. Worker Function-only metadata binding and protected-state post-check have not been performed. Verify already-present Run binding without writing it.
2. aiReconcileInputs creation, scoped actual-resource IAM, immediate Scheduler pause/GET and no lastAttemptTime verification.
3. aiRejectLateUpload creation, scoped actual-resource IAM, US-CENTRAL1 bucket finalized Eventarc filter and Tokyo destination verification.
4. All12 ACTIVE/full source/runtime/region/trigger/SA/private/closed, queue/Scheduler PAUSED and complete final protected-state/rejection audit.

The previous STOPPED journals (initial4, firstresume6) and this zero-write STOPPED journal are retained. No mutation is retried after the timeout. A subsequent resume must use fresh current metadata/source/artifact/approval, not clear a stopped journal or recreate/update existing10.

Phase3b deferred: admission endpoints and worker exist; finalize endpoint does not yet exist. Real deletion-time admission/delayed-worker/late-upload cleanup E2E remains Phase5 after separate approval and internal UID confirmation. Future public HTTP ingress for nine Callables + Firebase Auth + one internal UID is NOT enabled.

No Phase5, public invoker/ingress, allowed UID, sharing ON, queue/Scheduler resume, Secret/lifecycle/Rules/index change, full deploy, --force, Git commit/push/merge, App Store release or Aogaku-clean change.

## Files / evidence

- scripts/deploy_production_phase4_final.cjs: independent fresh23 remainder guard; CREATE only last2; worker Function IAM only; all10 source/metadata/Run IAM immutable; existing Run binding cannot be re-added; Scheduler immediate pause and zero-attempt assertion.
- scripts/test_production_phase4_final.cjs: five additional remainder safety tests.
- scripts/verify_production_phase4_final_stop.cjs: all23 read-only stopped-state source/private/anonymous audit, executed PASS.
- scripts/verify_production_phase4_final_closed.cjs: all12 final read-only audit prepared, NOT executed.
- This report and link from previous resume report. Functions implementation source unchanged.

Private/ignored build/production-phase4-final/ (directory700, files600) retains fresh baseline/approval/full manifests, STOPPED zero-write journal, stop audits and test logs. No signed uploadURL, token, credential or Secret payload saved. Earlier Dev/Phase3b/Phase4 evidence remains preserved.

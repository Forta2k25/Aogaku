> Subsequent final-remainder attempt: [PHASE4_FINAL_REMAINDER_RESULT.md](PHASE4_FINAL_REMAINDER_RESULT.md). This report preserves the previous six-creation partial-success record.

# Phase 4 resume - PARTIAL SUCCESS / STOPPED SAFE

Phase 4 remains incomplete. Six of the approved remaining eight Functions were created individually. The successful first four were neither recreated nor updated. After aiProcessSource operation completion, source verification and a resource-scoped Run invoker binding succeeded, the following Run IAM GET returned HTTP 503 / UNAVAILABLE. Deployment stopped immediately. No CREATE, IAM mutation or subsequent Function was retried. Read-only stopped-state audit subsequently passed.

Report time: 2026-10-07T02:05:41.227690+00:00

## Fresh identity, approval and artifact

Latest metadata verified project forta-aogaku / number 505828754933 / bucket forta-aogaku.firebasestorage.app / Release bundle com.forta2k25.Aogaku. Named DB aogaku-ai: Native, asia-northeast1, delete protection ON, full client deny Rules, required indexes READY. Fresh seventeen-Function metadata, installed full manifests, updateTimes, IAM, database/rules/indexes/Storage/queue/Secret metadata and SA inventories formed this attempt baseline. Old approval/upload URL/stopped baseline were not used for execution authorization. Original manifests were used only to verify preserved existing code.

Fresh closed candidate has the exact same nine-file full source manifest as the immutable first four; all ten installed AI manifests match:

`34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`

No .env, plist, credentials, fixture, tests or Secret payload in ZIP. All ten are Gen2 / Node22 / asia-northeast1; runtime SA aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com; explicit named DB aogaku-ai; allowedUIDs=[]; sharing false and production hard OFF.

## Twelve Functions

| Function | Status | Trigger | updateTime |
|---|---|---|---|
| aiCreateSource | Preserved / ACTIVE / unchanged | Callable HTTPS | 2026-10-07T01:05:42.041243896Z |
| aiCompleteSource | Preserved / ACTIVE / unchanged | Callable HTTPS | 2026-10-07T01:09:13.057734690Z |
| aiGetSource | Preserved / ACTIVE / unchanged | Callable HTTPS | 2026-10-07T01:12:01.146639576Z |
| aiListSources | Preserved / ACTIVE / unchanged | Callable HTTPS | 2026-10-07T01:14:54.199119370Z |
| aiGetEvidence | Created / ACTIVE / individual post-check PASS | Callable HTTPS | 2026-10-07T01:44:09.072151942Z |
| aiRetrySource | Created / ACTIVE / individual post-check PASS | Callable HTTPS | 2026-10-07T01:47:59.794532874Z |
| aiUpdateSource | Created / ACTIVE / individual post-check PASS | Callable HTTPS | 2026-10-07T01:50:58.826030128Z |
| aiDeleteSource | Created / ACTIVE / individual post-check PASS | Callable HTTPS | 2026-10-07T01:54:09.740232344Z |
| aiRetrieveContext | Created / ACTIVE / individual post-check PASS | Callable HTTPS | 2026-10-07T01:57:13.950479792Z |
| aiProcessSource | Created / ACTIVE / source PASS / stopped during IAM post-check | TaskQueue HTTPS | 2026-10-07T02:00:13.221571590Z |
| aiReconcileInputs | NOT CREATED | Scheduler HTTPS | - |
| aiRejectLateUpload | NOT CREATED | Storage/Eventarc | - |

Nine Callables: 256Mi, CPU0.1666, timeout120s, min0/max10, concurrency1. Worker: 2Gi, CPU1, timeout1800s, min0/max3, concurrency1. Planned Scheduler/finalize contracts are not installed or verified in production yet.

## Exact error and changes

- aiProcessSource staging, CREATE, operation, installed full source, runtime/SA/closed flags and initial private IAM check succeeded.
- Actual Run resource projects/forta-aogaku/locations/asia-northeast1/services/aiprocesssource was verified before adding only runtime SA roles/run.invoker with current etag. SET succeeded; no existing binding removed.
- Immediately following GET run.googleapis.com/v1/projects/forta-aogaku/locations/asia-northeast1/services/aiprocesssource:getIamPolicy returned 503 / UNAVAILABLE. Root cause is not established. Signed upload URLs, credentials and tokens were not logged.
- Worker Function-scoped projects/forta-aogaku/roles/aogakuAIFunctionMetadata binding was NOT added. A subsequent read-only GET confirms it absent.
- No other IAM addition. No project-wide IAM change or public invoker.
- Scheduler/Eventarc/PubSub trigger resources were NOT created. Existing queue rate/retry config and PAUSED state unchanged.

The stopped-state GET subsequently confirmed the new exact Run invoker binding. This did not authorize resuming deployment; execution.json remains STOPPED.

## Read-only stopped-state post-check

- All 23 installed full SourceCodeGet manifests/updateTimes verified. Thirteen legacy Functions and first four AI Functions retain their fresh-baseline source, metadata, updateTime and IAM.
- Ten AI Functions ACTIVE, exact source, Node22/Tokyo/runtime SA, explicit named DB, empty cohort, sharing OFF, private IAM. Run invoker IAM checks are not disabled.
- Ten AI Functions x Run/cloudfunctions.net endpoints = 20 anonymous POST probes, ALL 403. No absent endpoint/404 counted as security pass.
- Valid production/Dev user tokens were NOT acquired or probed live. Actual no-public-invoker plus enabled Run IAM checking establishes private boundary; exact installed-source closed gates were tested locally. No Auth fixture or UID activation.
- Exact artifact worker rejects closed requests before processing/Firestore/Auth/provider I/O. No queue dispatch or normal-use E2E performed in Phase4.
- Default/named Rules, indexes, fieldOverrides, Storage Rules, lifecycle/soft delete, project and existing resource IAM, Secret metadata/versions/bindings, API/SA inventories and zero user-managed SA keys unchanged. No Secret payload read or rotation.
- Queue projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource remains PAUSED. Scheduler absent; its PAUSED check cannot pass yet. No resume/run.
- No Firestore/Auth/existing-bucket user-data writes/deletes. Changes limited to six authorized Functions, GCF source/build staging and one actual worker Run-scoped binding.

## Fresh local verification

- TypeScript build PASS; domain 13/13 PASS.
- Firestore/Storage Emulator rollout regression 50/50 PASS, zero fail/skip, covering existing entries/avatars, legacy AI/provider mock/quota/refund/deletion/friend regressions and named/default separation.
- Exact artifact closed/security/deploy/resume guards 11/11 PASS, zero fail/skip.
- Production / named DB / rollout safety 23/23 PASS.
- Initial local Python runner used two wrong filenames; corrected invocation passed all23. Initial read-only audit had a local display-variable typo; corrected audit passed all23 installed sources. No cloud mutation retried for these harness fixes.

## Remaining blockers and next approval

Phase4 is NOT fully successful. Phase5 blockers are NOT zero.

1. Complete worker Function-scoped metadata binding and its individual protected-state post-check. Existing Run invoker needs verification, not duplicate addition.
2. Create aiReconcileInputs; verify actual Run resource before scoped IAM; create Scheduler and immediately PAUSE/GET.
3. Create aiRejectLateUpload; verify actual Run resource before scoped IAM; verify US-CENTRAL1 Eventarc bucket finalized filter and Tokyo destination; unrelated Storage prefix no-op.
4. Final all-twelve full source/runtime/trigger/SA/private/closed checks, anonymous refusal, queue/Scheduler PAUSED and protected-state audit.

Resume requires separate user approval for REMAINING work only and fresh current23 metadata/source/IAM + artifact/approval. Do not recreate/update any successful ten, reuse signed upload URLs, clear the STOPPED journal or reuse this approval.

Phase3b deferred tests: admission endpoints and worker now exist; Storage finalize endpoint does not. Deletion-time new admission, delayed-worker refusal and exact-generation late-upload cleanup remain mandatory Phase5 E2E after Phase4 completion, separate approval and internal UID confirmation.

Future nine Callable public HTTP ingress + mandatory Firebase Auth + exactly one internal UID was NOT enabled. No UID addition, public invoker, queue/Scheduler resume, sharing ON, Secret/lifecycle change, Git commit/push/merge, App Store release or Aogaku-clean modification.

## Files / private evidence

- scripts/deploy_production_phase4_resume.cjs: independent execution and fresh17 baseline; remaining8 CREATE only; first4 immutable; exact artifact dependency hashes; safe failing read method/path.
- scripts/test_production_phase4_resume.cjs: five additional resume/immutable/Secret/public/broad-IAM/resume safety tests.
- scripts/verify_production_phase4_resume_stop.cjs: read-only all23 source/private/anonymous audit; executed PASS.
- scripts/verify_production_phase4_resume_closed.cjs: all-twelve final read-only rejection audit, prepared but NOT executed.
- This report and a historical report link. Functions implementation source unchanged this attempt.

Ignored private evidence build/production-phase4-resume/ (directory700 / files600): fresh17 metadata/source/approval, six CREATE/operation/installed source receipts, STOPPED journal, stopped-state23 audit and test logs. No signed URLs, tokens or Secret payload stored. Original build/production-phase4/ STOPPED journal and Dev/Phase3b evidence preserved.

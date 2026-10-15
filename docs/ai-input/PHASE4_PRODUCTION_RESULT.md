> Subsequent reapproved remaining-work results: [PHASE4_RESUME_RESULT.md](PHASE4_RESUME_RESULT.md). This document preserves the original partial-success record.

# Phase 4 — PARTIAL SUCCESS / STOPPED SAFE

As of 2026-10-07T10:21:19, Phase 4 is **not complete**. Only four of the approved twelve new Functions were created. After `aiListSources` staging, CREATE, operation completion, installed full-source manifest comparison and initial private IAM checks succeeded, a Cloud Functions API GET during the protected-state post-check returned HTTP 503 / UNAVAILABLE. The wrapper stopped immediately; no subsequent Function CREATE or mutation retry was executed. The exact failing read endpoint and root cause are not established. Subsequent read-only metadata/source audits succeeded; this does not authorize continuation or erase the original error.

## Identity and added Functions

Freshly verified target: project `forta-aogaku`, number `505828754933`, default bucket `forta-aogaku.firebasestorage.app` / US-CENTRAL1, Release bundle `com.forta2k25.Aogaku`, named Firestore `aogaku-ai` / Native / asia-northeast1 / delete protection ON. Existing default four composite indexes and eight explicit fieldOverrides unchanged; the API also returns its normal `__default__` field record, which is not counted as an explicit fieldOverride. Named indexes remain READY and client Rules remain full deny.

All four additions are Gen2 / Node22 / asia-northeast1 / Callable HTTPS, runtime SA `aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com`, timeout 120s, memory 256Mi, CPU 0.1666, concurrency 1, max 10, min 0. All use explicit named DB env `aogaku-ai`, allowedUIDs `[]`, sharing `false` (production also hard OFF). No public invoker was added, even temporarily. The fresh four installed full manifests equal closed artifact SHA256:

`34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`

| Added Function | Actual updateTime | Public invoker |
|---|---|---|
| aiCreateSource | 2026-10-07T01:05:42.041243896Z | false |
| aiCompleteSource | 2026-10-07T01:09:13.057734690Z | false |
| aiGetSource | 2026-10-07T01:12:01.146639576Z | false |
| aiListSources | 2026-10-07T01:14:54.199119370Z | false |

Eight Functions **not created**:

- `aiGetEvidence`
- `aiRetrySource`
- `aiUpdateSource`
- `aiDeleteSource`
- `aiRetrieveContext`
- `aiProcessSource`
- `aiReconcileInputs`
- `aiRejectLateUpload`

No `aiLinkSourceOffering`, legacy replacement, full Functions deploy, Function deletion or --force was used. The deployment tool uses the pinned Firebase CLI14.17 API payload converter but performs exact individual GCFv2 CREATE calls, rather than invoking a CLI deploy that automatically makes Callable ingress public. SDK-only source ZIP contains nine files, no .env/plist/credentials/test fixtures. Public runtime identity/config flags are injected through the exact reviewed API payload.

## Stopped-state post-check

PASS after the stop, read-only:

- Actual full SourceCodeGet manifests and updateTimes of **all thirteen** existing Functions unchanged, including old AI3, deletion3, friend/notification and catalog Functions.
- All four newly installed actual source manifests match the approved artifact; runtime/region/SA/flags reverified from live metadata.
- Four Functions x Cloud Run/cloudfunctions.net endpoints = **eight anonymous HTTP probes, all 403**.
- All four Run IAM policies contain neither allUsers nor allAuthenticatedUsers. Closed application gates in the exact source additionally reject all user UIDs before Firestore/Auth/provider I/O.
- Default/named DB configuration, Rules, composite indexes, fieldOverrides, Storage Rules and privacy, project/resource IAM, API/SA inventory, zero user-managed SA keys, all Secret metadata/versions/bindings, lifecycle and soft-delete unchanged.
- Queue `aiProcessSource` / asia-northeast1 remains **PAUSED**, with unchanged rate/retry config and IAM.
- Scheduler and AI Eventarc were **not created**: their Functions were not reached. No queue or Scheduler resume.
- IAM additions = **zero**. No new worker/Run-scoped binding was required for these four Callables. Phase1 IAM and Secret Accessor remain unchanged; GROQ version1 ENABLED unchanged, no Secret payload read or version rotation.
- No Auth fixture, Firestore user data, default bucket object or real user was created/modified for this Phase4 attempt. Only authorized GCF source staging/build artifacts and the four Functions were added.

Valid production authenticated UID and valid Dev-token live probes were **not run** after the stop. The all-twelve closed rejection harness is prepared but was not executed, and no synthetic Auth fixture was created. No absent endpoint/404 is treated as a security pass.

## Local verification

- TypeScript build PASS; domain 13/13 PASS.
- Firestore/Storage Emulator rollout regression **50/50 PASS, zero fail/skip**, including old AI/provider mock/quota/refund/deletion/friend regression, named/default separation and existing entries/avatars permissions.
- Exact new closed artifact and deployment guards **6/6 PASS**, including every Callable rejecting users before I/O, worker rejecting closed tasks, Scheduler no-op before DB access, unrelated Storage paths ignored, explicit invalid DB IDs rejected, no mutation outside allowlist.
- Exact Phase3b database runtime 5/5 PASS; production safety 12/12 PASS; named database safety 6/6 PASS; rollout phase safety 5/5 PASS.

## Deferred tests / remaining conditions

Phase3b's three integration tests remain deferred:

1. New input admission while deletion starts: Phase5 with explicitly approved internal UID/fixture, verify fence before upload/processing and no quota recreation.
2. Delayed new worker: first deploy/verify `aiProcessSource`, keep queue paused in Phase4; Phase5 check a deleted/tombstoned fixture cannot process/publish or recreate usage.
3. Late upload finalize cleanup: first deploy/verify `aiRejectLateUpload` and actual US-CENTRAL1 Eventarc -> Tokyo destination; Phase5 verify exact-generation late raw removal while unrelated avatars are ignored.

These worker/trigger resources do **not yet exist** in production; their existence requirement is not marked PASS. No normal AI usage was activated to run deferred tests.

Phase4 completion blocker: remaining eight Functions plus their minimal actual-resource IAM, paused Scheduler, Eventarc/source/profile post-checks and live all-twelve rejection tests. Resume requires explicit user approval **for remaining work only**, fresh seventeen-Function metadata/source/IAM baseline and fresh approval/artifact receipts; preserve these four additions and original stopped journal. No CREATE/update of the successful four is planned. The current guard refuses to continue from STOPPED; never clear it as a workaround. Do not reuse upload URLs or old approvals.

Phase5 also needs an ingress decision: all new Callables are IAM private, so standard Firebase Auth tokens alone cannot pass Cloud Run IAM. A design-only question was sent; no decision or ingress change is assumed. Either future separately approved public HTTP ingress for nine Callables with Firebase Auth + exact pilot UID gate, or an IAM-authenticated internal bridge, is required before iOS E2E. Phase5 is not authorized, its UID is not requested/set, and its blockers are **not zero** at this stopped state.

No GitHub push/commit/main or PR merge, App Store release, sharing ON, general AI release, Aogaku-clean change, Secret rotation, Rules/index/lifecycle change, IAM expansion, queue/Scheduler resume or Phase5 action occurred.

## Changed files this turn

- `functions/src/ai/index.ts`: closed predicate; worker rejects closed tasks before DB access; Scheduler returns before maintenance/DB I/O.
- `scripts/deploy_production_phase4.cjs`: fresh closed artifact, exact individual new-AI12 CREATE allowlist, stopped-state preservation, resource-scoped IAM guards, immediate Scheduler pause, source/protected-state checks.
- `scripts/test_production_phase4.cjs`: six exact artifact/security/safety tests.
- `scripts/verify_production_phase4_closed.cjs`: future all-twelve token rejection harness, prepared only, not executed.
- `scripts/verify_production_phase4_stop.cjs`: read-only all-seventeen source/IAM/anonymous-rejection audit after stop.
- `scripts/firebase_production.py`: reject generic closed CLI Functions deploy that would publish Callable ingress.
- `scripts/test_production_safety.py`: missing named DB case now uses an isolated fixture, independent of rollout progress.
- `Config/Production/rollout.phases.json`, `docs/ai-input/FINAL_PRODUCTION_ROLLOUT.md`: all twelve private in Phase4, exact CREATE wrapper, untouched paused queue, inert closed Scheduler; Phase5 ingress decision remains separate.
- `docs/ai-input/PHASE4_PRODUCTION_RESULT.md`: this report.

Ignored/generated/private evidence: `build/production-phase4/` (receipts, signed-URL-free metadata, logs, source ZIPs, full manifests); earlier Phase3b and Dev evidence remain preserved. No signed URL, token, password or Secret payload was saved in new receipts. Before this attempt, 163 source/evidence files were archived privately at `/Users/shum/Documents/Codex/2026-10-06/y/work/production-phase4-predeploy-backup-20261007-095441`.

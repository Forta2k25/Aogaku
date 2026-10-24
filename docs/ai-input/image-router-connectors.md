# Image-only connector routing correction

## Cause and scope

The synthetic standalone Scientific Method image reached `ready` as `vision_ocr`.
Vision's OCR probe omitted the short arrow glyphs, leaving `relationMark=false`.
The existing long-stroke detector required at least 25 pixels / 6.5% of the
analysis canvas's short side; the glyph arrows produced `lineScore=0`.
Consequently a high-quality OCR probe was classified as simple text. This was
not an Evidence adoption error or an AI-to-OCR fallback: Qwen was never called.

`image-auto-v1` now has an additional local raster signal. At the already bounded
640-pixel analysis resolution, remove OCR word boxes with existing padding,
then inspect 8-connected unrecognized ink components. Elongated, non-filled
components in blank gaps between nearby text regions indicate connectors.
`connectorComponents > 0` promotes image complexity to the existing high
complexity range (`raster_connectors_between_text`) and selects `multimodal_ai`.
No new external AI request is made for classification. A selected AI failure
remains retryable; OCR probe text cannot become final Evidence as a fallback.

The detector is a conservative layout heuristic, not a semantic arrow reader.
It does not infer arrow direction, entities or causal relationships. Faint,
very tiny, obscured or unusual connectors can still require more regression
coverage; only the selected Qwen result describes visually grounded relations.

## Preserved contracts

- PDF uses exactly the previous feature extraction and decisions; the additional
  connector feature is absent for PDF pages. Shared thresholds and weights stay
  unchanged.
- `image-auto-v1`, `pdf-auto-v1`, `visual-router-v1` and model
  `qwen/qwen3.8-27b` are unchanged. `connectorComponents` is optional metadata.
- FinalText -> Unit -> chunks -> Evidence -> retrieval remains unchanged.
- Grounded prompt, audio/note pipeline, pricing, quota, Rules, IAM, Secrets,
  allowlists, sharing and Scheduler configuration are unchanged.
- Existing source checkpoints/results are retained and never bulk-reprocessed.

## Validation operators

`image_router_fixtures.cjs` generates synthetic text, paragraph, nodes,
concept/flow diagrams, chart, text with a visual, table, a two-label short arrow,
the exact failed six-label arrow pixels, and the previously successful three-page
mixed PDF. Binary fixtures, registry/auth data and traces stay under ignored
`build/` with private file modes.

`image_router_dev.cjs` is Dev-only: preserve the live installed package and
replace exactly `lib/ai/visualRouter.js` and `lib/ai/visualExtraction.js`; source-only
PATCH `aiProcessSource` once while the queue is paused/drained. Check full
installed source and protected metadata before restoring the queue. Never replay
an attempted PATCH/provider fixture automatically. Verify real route, provider,
model, checkpoints, named chunks, Evidence and retrieved text for each fixture.
Own disposable Dev cleanup is permitted only after the entire trace passes.

Production fixtures from the stopped rollout remain intact. The operator never
reprocesses them. Pending disposable nonpilot cleanup requires the original
consent and a fully passing final audit.

## Minimal production plan — requires explicit approval

Fresh read-only audit verified 25 installed full source manifests, unchanged
protected configuration, 2 existing pilots, queue `RUNNING`, Scheduler `PAUSED`
and sharing OFF. The offline review `production_image_router_review.cjs` emits
an unapproved private artifact, based on the live worker ZIP and exactly the two
compiled routing modules. It cannot deploy or call network APIs.

Only **`aiProcessSource`** needs a source update. The other nine migration
Functions have no image-routing implementation change: request/response schemas,
capabilities, admission, storage, Evidence and retrieval contracts are unchanged.
No ten-Function redeploy is needed. The candidate archive preserves all other
files, including entrypoint, lockfile, provider/prompt and account deletion code.

After explicit production approval:

1. Repeat fresh full-source/protected preflight; stop on drift. Verify the new
   artifact matches the reviewed two-module delta; never reuse stale approval.
2. Pause only `aiProcessSource` queue and prove dispatches and worker leases are
   drained. Scheduler remains paused; sharing and exact live allowlist retained.
3. Stage once and source-only PATCH the existing worker once. No env/IAM/Secret
   changes. Await operation completion; do not automatically repeat mutation.
4. Verify full installed source, runtime/SA/trigger/env/IAM, all other Functions,
   Rules/indexes/Secrets/lifecycle and queue configuration unchanged.
5. Only after all checks pass restore the queue to its initial `RUNNING` state.
6. With an existing pilot, create fresh synthetic short-arrow and plain images,
   and mixed PDF. Verify arrow -> Groq/Qwen and exact finalText -> Unit -> chunks
   -> Evidence -> retrieval; text -> OCR; PDF native/OCR/AI regression. Verify
   admission/direct-access restrictions and unchanged safety configuration.
7. Physical normal `Aogaku` UI verification follows separately; do not wait for
   an iPhone to audit the backend.

Failure before completed post-check: stop with queue paused, record the current
operation/revision and source; no automatic rollback or extra mutations.
Rollback requires separate approval: restore the saved previous worker source
ZIP only, verify protected state, then restore queue. Old sources retain their
results; the old worker would retain the known short-arrow routing limitation.

## Dev results and pre-approval review — 2026-10-09

- TypeScript build PASS; final domain/recognition/router/deploy safety suite
  93/93 PASS; real local Firestore/Storage Emulator 51/51 PASS; prompt deployment
  selectors 3/3 PASS. Geometry tests include 320/800/1600-pixel image widths,
  OCR-omitted arrows, fail-without-Evidence-fallback and unchanged PDF signals.
- Dev production-like source-only worker update verified full installed source,
  unchanged env/IAM/runtime/trigger and all unselected Functions. Dev queue
  restored RUNNING after post-check, then 10 synthetic inputs passed:

| Input | Actual selected route |
| --- | --- |
| Plain text | vision_ocr |
| Paragraph screenshot | vision_ocr |
| Multiple nodes + connectors | multimodal_ai |
| Concept diagram | multimodal_ai |
| Chart | multimodal_ai |
| Visual + text | multimodal_ai |
| Table fixture | multimodal_ai (existing rule retained) |
| Observation -> Question short arrow | multimodal_ai |
| Exact previously failed six-label short-arrow flow | multimodal_ai |
| Previously successful mixed PDF | native_text / vision_ocr / multimodal_ai |

- Exact failed image: still `relationMark=false`, `lineScore=0`, now
  `connectorComponents=5`; provider `groq`, model `qwen/qwen3.8-27b`.
  Input 2,497 / output 236 / total 2,733 tokens; AI cost $0.0029416,
  existing OCR probe cost $0.0015, estimated total $0.0044416.
  Page processing 1,772 ms. Unit -> named chunks -> Evidence -> retrieveContext
  text/locator equality passed. The five visible downward connections survive,
  with no invented Result -> Observation edge.
- One transient Groq `IMAGE_AI_RATE_LIMIT` was observed on the concept fixture.
  Existing queue retry/backoff recovered; the operator never resent a source,
  manually retried a provider or changed quota/configuration.
- All ten own Dev fixtures/Auth/raw/derived/chunks/runs/jobs/usage cleaned;
  deletion tombstones and private validation traces retained. Local Auth tokens
  removed. Existing Dev users/data were not cleanup targets.
- Fresh production 25/25 full installed source checks PASS; protected state PASS;
  production mutations zero. The short-arrow fix is **not yet deployed there**.
- Secret/private Auth UID scan PASS on changed/untracked candidates and tracked
  files; private evidence is ignored and staging remains empty. A Firestore
  database resource UUID match was classified separately from private Auth UIDs.
- No commit, push, merge or App Store action. Branch remains
  `codex/ai-recognition-comparison-lab`. Previously uncommitted grounded prompt,
  iOS UI and Scheme changes were preserved byte-for-byte.

## Files added/changed in this correction

- `functions/src/ai/visualRouter.ts`
- `functions/src/ai/visualExtraction.ts`
- `functions/test/visual-router.test.cjs`
- `functions/test/emulator.test.cjs`
- `scripts/image_router_fixtures.cjs`
- `scripts/image_router_dev.cjs`
- `scripts/test_image_router_dev.cjs`
- `scripts/production_image_router_review.cjs`
- `scripts/test_production_image_router_review.cjs`
- `scripts/test_production_recognition_review.cjs` (assert stale artifact cannot
  authorize the two changed routing modules; preserve prior rollout artifact)
- `docs/ai-input/image-router-connectors.md`

No other preexisting changes are attributed to this correction. Generated
compiled code, fixture binaries, auth/config and cloud evidence remain excluded.

## Approved production update and safe stop — 2026-10-09

Only `aiProcessSource` was source-only PATCHed once after fresh 25-source and
protected-state preflight, queue pause and zero-dispatch/lease drain. The
reviewed ZIP changed exactly `lib/ai/visualRouter.js` and
`lib/ai/visualExtraction.js`; no provider/prompt/Evidence/PDF/configuration
module changed.

- Revision: `aiprocesssource-00005-tab` -> `aiprocesssource-00006-cif`.
- Installed full-source manifest SHA256:
  `f43c03eca14f63c9c1bc272ba260f7846d5fc6d87f7b4f74fe687282085a0d1e`.
- Full installed source/runtime/SA/trigger/env/IAM matched; other 24 Functions
  unchanged. All post-checks and 27 live Auth admission checks passed before
  restoring queue to RUNNING. Scheduler PAUSED, sharing OFF, exact two live
  pilots, Rules/indexes/IAM/Secret versions/lifecycle unchanged.
- Five fresh production fixtures reached ready: plain/paragraph -> vision_ocr;
  two-label arrow/six-label flow -> multimodal_ai; mixed PDF -> native_text /
  vision_ocr / multimodal_ai. Every selected Unit matched chunks, Evidence and
  retrieveContext text and locator. The six-label flow retained all five visible
  connections and no invented return edge.
- Six-label flow: connectorComponents=5, OCR relationMark=false, lineScore=0;
  Groq qwen/qwen3.8-27b; 2,497 input / 236 output / 2,733 total tokens.
  AI estimate $0.0029416 + OCR probe $0.0015 = $0.0044416; selected-page
  processing 3,688 ms; complete extraction metadata 5,205 ms.

The final legacy-preservation guard stopped before direct-access/UI/final E2E
completion: it hashed Firestore REST JSON with order-dependent JSON.stringify.
A read-only diagnosis confirmed the old OCR and old AI records match their
original canonical hashes and updateTimes. This is a test-operator false
positive, not an observed source/contract/data drift. The local operator now
uses the existing recursive canonical digest and separately checks updateTime;
its regression rejects real content/timestamp changes but accepts reordered
maps. The stopped execution receipt is retained unchanged.

No further production mutation, rollback, fixture replay, Auth cleanup, commit
or push was performed after the assertion. Queue remains RUNNING (successfully
restored before E2E), and a read-only final protected-state audit passes.
Production E2E is **INPUTS PASS / FINAL AUDIT INCOMPLETE**, not COMPLETE.

Resume after review/approval using read-only checks on the five already-ready
fixtures; do not create/reprocess inputs or PATCH the worker again. Verify the
remaining legacy/chunks/default boundary/direct-access checks, generate the
private UIKit mirror, run offline XCTest, then the original approved disposable
Auth cleanup and final protected audit. Only after full success perform the
secret/private-UID scan and commit/push. Physical normal Aogaku UI remains a
separate follow-up. Private receipts/fixtures stay ignored under build/.


## Feature-branch保存時の確認 — 2026-10-09

利用者が通常Aogaku実機での確認を完了し、正常動作を確認したと報告。
この実機確認に基づき、最新版を既存codex/ai-recognition-comparison-labへ
commit/pushする明示承認を受けた。今回の保存作業はソース、テスト、検証用
operatorと非機密docsのみを対象とし、本番deployや設定変更を実行しない。
通常Aogaku Schemeの個人環境Release変更、private UID/config/token、原本、
binary fixture、source ZIP、production evidence、生成物は保存対象外。

前回のE2E operatorの最終guard停止記録は履歴として保持する。5入力の
routeと本文/locator伝播はPASS済みで、停止原因のmap順序依存hashはローカル
operatorと回帰テストで修正済み。未実行の自動検証をPASSと書き換えず、
今回の実機確認とGit保存の承認を別の確認として記録する。

# Visual Router latency optimization — Dev review

Baseline: `b3a04d1d7d0cf47f76199c4b46b3451adc795dc5`.
Branch: `codex/ai-recognition-comparison-lab`. Measurements: 2026-10-09.
Dev review completed. Production rollout of exactly four Functions and subsequent
commit/push were explicitly approved on 2026-10-09. No general user release,
Phase 5b, merge or App Store publication is authorized.

## Contracts and implementation

The Router weights/thresholds, `image-auto-v1`, `pdf-auto-v1`, `visual-router-v1`,
Groq `qwen/qwen3.8-27b`, Grounded Evidence prompt, pricing, quotas, audio/note,
page locators and selected-route text contract are preserved. New optional fields
are backward compatible. OCR output never replaces a selected AI result; AI errors
remain retryable AI errors and never trigger an OCR fallback.

- **Image fast path:** local raster analysis at at most 640px estimates substantial
  text bands and detects connectors outside them. A positive connector between at
  least two bands enters the existing high-complexity AI decision. This makes no
  external Router call. Ambiguous layouts retain the existing OCR probe. Metadata
  exposes `ocrProbeSkipped` and `ocrProbeSkipReason=local_connector_signal`.
- **PDF concurrency:** `VISUAL_EXECUTION` defines AI=2, OCR=3, page jobs=4.
  Native pages publish first; provider work has bounded concurrency. Results retain
  page order. On failure, active work drains, new jobs stop and completed checkpoints
  survive. A retry does not call providers again for completed pages.
- **Checkpoint lookup:** one bounded Storage prefix listing replaces per-page 404
  downloads for a fresh visual source. An oversized catalog retains the old lookup.
  Audio checkpoint behavior is unchanged. Existing runtime Storage list permission
  is sufficient; no new IAM role is proposed.
- **Native PDF:** pages without visual drawing/image requirements keep native text
  without rendering or providers. Vector paths still require visual inspection,
  including single paths that may contain a connector. The rendered bitmap is reused
  for provider work. No threshold was weakened to declare a diagram “text-only”.
- **Progressive preview:** completed pages live at
  `aiSources/{sourceId}/runs/{currentLease}/previewPages/{zeroPaddedPageNumber}` in
  `aogaku-ai`. First native page publishes immediately; subsequent native pages
  batch in groups of five; provider pages publish on completion. Owner/lease/fence
  checks protect each transaction. `aiGetEvidence(preview:true)` is an explicit,
  owner-only processing view with its own cursor, version and progress.
  It does not activate a run or populate final run chunks. Standard Evidence and
  `aiRetrieveContext` continue to use the existing published active run; an unfinished
  new PDF cannot enter RAG. Existing legacy `partial_ready` behavior is preserved.
  Retry changes the preview lease. Recursive account cleanup includes missing-parent
  runs/previewPages.
- **iOS:** optional models retain old-source decoding. A processing PDF can show
  completed page text with “途中結果・検索対象外”. Whole-document token/cost totals are
  deferred until completion. Final page headers and body adoption are unchanged.
  Polling waits 1s initially, then 2s, then 3s; a ready response is consumed immediately
  instead of adding the previous fixed 3s delay. A preview/final race is reread normally.

## Instrumentation and interpretation

Source and Firestore run metadata carry optional `visual-latency-v1` diagnostics:
`uploadMs`, `uploadTimingKind`, `queueWaitMs`, `workerStartupMs`, `routerMs`,
`nativeExtractionMs`, `ocrProbeMs`, `ocrMs`, `aiMs`, `persistenceMs`,
`totalProcessingMs`, page counts, per-page times and max page time.
`aiGetEvidence` returns `evidenceMs` for that read, without adding a write on every
read. Stored `evidenceMs` is null until a read supplies its response measurement.

- New iOS uploads report successful transfer time; old clients use the server window
  from source creation to object creation, labeled separately. It is not pure transfer.
- Queue wait is job creation to handler entry, including dispatch/platform delay.
  A retry whose old job document has been removed reports unknown (`null`).
  This is not a claim to measure exact dispatch time.
- Worker startup is handler entry through guarded source/raw download preparation.
  `firstInvocation` indicates the first call in that process. It is **not** a measured
  infrastructure cold start. `coldStartMs=null`; do not justify minInstances/CPU/memory
  changes from this signal.
- Provider start/end timestamps are compact spans (bounded 100), not raw responses.
  Provider stage durations sum across concurrent work and need not add to wall time.
- `totalProcessingMs` covers the successful worker attempt up to publication setup;
  it excludes upload, failed-attempt/backoff time, and the final transaction tail.
  `serverReadyMs=updatedAt-createdAt` covers source-to-ready elapsed time.
- `providerCalls` counts logical OCR/recognition operations **in the current attempt**,
  not every HTTP request or historical failed attempt. Groq model verification is
  an additional HTTP read. Cached pages retain historical usage/cost; zero current
  calls must not be reported as zero billed work.
- Rendering/previews/checkpoint persistence add storage and Firestore operations.
  Provider estimated cost excludes those platform costs and free monthly tiers.

## Benchmark method and private evidence

`visual_latency_dev.cjs` uses fresh Dev snapshots, source-only reviewed ZIPs,
installed full-source equality and protected-state checks. Writes are never retried.
Before is an **instrumented sequential reference**, with image fast path disabled;
preview/instrumentation are already present. It is not an untouched production
revision measurement. After enables the optimization and client upload telemetry.

`visual_latency_benchmark.cjs` processes fresh synthetic fixtures with actual Dev
Vision/Groq, validates selected Unit text, stored chunks, Evidence, paginated
retrieveContext and all locators, and asserts no source in default DB. Partial
previews cannot enter RAG while still processing. Final publication races are handled
by reread. Search uses its existing source cursor; the harness now reads all pages
rather than assuming the target is in the first 30 sources. These are harness fixes,
not changes to routing or retrieval contracts.

N=1 per case; shared Groq 429/backoff and cold/warm variance limit causal conclusions.
Resume reuses the exact already-created source and original bytes; no billed replay.
Client elapsed times from a resumed session are invalid comparisons. Server timestamps
are used for those cases. Private full text, tokens, UID/registry, ZIPs and binaries
remain under ignored `build/visual-latency/`; they must not be committed.

Resize experiments use the same 4032×3024 synthetic image at original/2000/1600/1200,
with Dev-only task input and one-minute spacing. Production ignores this diagnostic
input. Router stays at 640px; normal provider bound remains **1800px** until repeatable
small-text/relationship quality evidence justifies a change.

## Production minimum plan — approval required

Only four Functions need source updates:

1. `aiProcessSource`: instrumentation, local connector fast path, bounded PDF work,
   preview persistence and checkpoint catalog.
2. `aiCompleteSource`: optional validated upload transfer timing; old clients work.
3. `aiGetSource`: optional latency/preview progress/version and update timestamp.
4. `aiGetEvidence`: explicit owner-only preview contract and response read timing.

`aiCreateSource`, `aiListSources`, retry/update/delete, `aiRetrieveContext`, Scheduler,
Storage-finalize, legacy and deletion Functions need no deployment. Existing response
fields stay compatible. No new Rules, indexes, Secret, IAM, allowlist or lifecycle.
No minInstances or queue concurrency/rate changes. `visual_latency_review.cjs` is an
**offline plan**, not a deploy operator or an approval receipt.

Before a separately approved production update: obtain fresh project identity,
all installed sources/revisions/config/IAM, named/default DB, Rules/indexes, queue,
Scheduler, Secret version and lifecycle; build and review exact artifacts; preserve
four deployed source ZIPs privately for rollback. Verify the live pilot allowlist,
sharing OFF and Scheduler PAUSED. Pause queue and drain. Update only the four named
Functions source-only, one at a time; validate full installed source and all protected
state after each. Do not automatically retry a write. On drift/source mismatch/error,
keep queue PAUSED and stop; do not silently rollback or resume.

After all four post-checks pass, restore the initial RUNNING queue, run pilot-only
synthetic eight-image/five-PDF checks, preview-to-final/RAG exclusion, duplicate/retry,
legacy OCR compatibility, account deletion/fences and direct-access rejection.
Verify final selected text/locators and privacy settings. Physical iPhone confirmation
of partial preview and perceived latency remains necessary. Rollback requires separate
approval and the four exact archived baseline sources, with the same queue/protected
checks; no data/schema rollback or reprocessing of existing materials is required.

## Measured before / after

Worker = successful attempt; Ready = source creation → ready; First = first preview write, or ready for images. Times are seconds. N=1; 429/retry differences are shown separately.

| Fixture | Worker before → after | Reduction | Ready before → after | First before → after | Attempts before → after |
|---|---:|---:|---:|---:|---:|
| plain | 5.466 → 5.452 | 0.3% | 13.431 → 17.213 | 13.431 → 17.213 | 1 → 1 |
| paragraph | 3.037 → 3.197 | -5.3% | 6.435 → 5.641 | 6.435 → 5.641 | 1 → 1 |
| two-label-arrow | 3.461 → 3.154 | 8.9% | 38.314 → 5.619 | 38.314 → 5.619 | 2 → 1 |
| short-arrow-flow | 4.401 → 3.376 | 23.3% | 6.464 → 5.472 | 6.464 → 5.472 | 1 → 1 |
| nodes | 3.379 → 3.373 | 0.2% | 38.064 → 37.114 | 38.064 → 37.114 | 2 → 2 |
| chart | 3.281 → 3.430 | -4.5% | 37.848 → 38.515 | 37.848 → 38.515 | 2 → 2 |
| photo-text | 3.389 → 3.635 | -7.3% | 100.548 → 38.723 | 100.548 → 38.723 | 3 → 2 |
| table | 4.145 → 4.255 | -2.7% | 5.680 → 6.006 | 5.680 → 6.006 | 1 → 1 |
| pdf-text-10 | 9.714 → 8.901 | 8.4% | 11.319 → 10.690 | 3.359 → 3.485 | 1 → 1 |
| pdf-mixed-30 | 9.997 → 8.283 | 17.1% | 69.738 → 61.773 | 3.493 → 3.413 | 2 → 2 |
| pdf-text-50 | 37.172 → 34.309 | 7.7% | 38.886 → 36.080 | 3.266 → 3.267 | 1 → 1 |
| pdf-scanned | 7.313 → 5.642 | 22.8% | 9.971 → 7.795 | 5.460 → 5.941 | 1 → 1 |
| pdf-diagram | 3.752 → 4.026 | -7.3% | 227.537 → 226.451 | 4.856 → 5.462 | 4 → 4 |

All 13 route arrays, selected Unit/chunk/Evidence/retrieval bodies and locators matched exactly between the real Dev runs. This fixture result does not prove accuracy for every real document.

### Stage times (seconds, before → after)

| Fixture | uploadMs | queueWaitMs | workerStartupMs | routerMs | nativeExtractionMs | ocrProbeMs | ocrMs | aiMs | persistenceMs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain | 0.703 → 0.369 | 0.904 → 1.311 | 2.035 → 2.073 | 0.117 → 0.169 | 0.000 → 0.000 | 0.000 → 0.000 | 0.826 → 0.707 | 0.000 → 0.000 | 0.662 → 1.045 |
| paragraph | 0.366 → 0.174 | 0.316 → 0.285 | 0.549 → 0.517 | 0.095 → 0.179 | 0.000 → 0.000 | 0.000 → 0.000 | 0.305 → 0.495 | 0.000 → 0.000 | 0.594 → 0.882 |
| two-label-arrow | 0.375 → 0.130 | unknown → 0.338 | 0.537 → 0.453 | 0.288 → 0.149 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 0.890 → 0.912 | 0.626 → 0.819 |
| short-arrow-flow | 0.595 → 0.130 | 0.303 → 0.262 | 0.525 → 0.451 | 0.111 → 0.223 | 0.000 → 0.000 | 0.189 → 0.000 | 0.000 → 0.000 | 1.137 → 1.103 | 0.616 → 0.801 |
| nodes | 0.412 → 0.250 | unknown → unknown | 0.474 → 0.466 | 0.297 → 0.181 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 0.924 → 1.044 | 0.603 → 0.781 |
| chart | 0.470 → 0.182 | unknown → unknown | 0.464 → 0.518 | 0.260 → 0.275 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 0.899 → 0.969 | 0.577 → 0.727 |
| photo-text | 0.665 → 0.162 | unknown → unknown | 0.507 → 0.479 | 0.217 → 0.180 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 1.054 → 1.233 | 0.563 → 0.703 |
| table | 0.382 → 0.113 | 0.275 → 0.314 | 0.554 → 0.460 | 0.071 → 0.371 | 0.000 → 0.000 | 0.230 → 0.281 | 0.000 → 0.000 | 0.956 → 1.090 | 0.569 → 0.810 |
| pdf-text-10 | 0.394 → 0.130 | 0.231 → 0.324 | 0.461 → 0.407 | 3.398 → 3.623 | 0.195 → 0.192 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 1.307 → 2.180 |
| pdf-mixed-30 | 0.405 → 0.167 | unknown → unknown | 0.505 → 0.484 | 1.123 → 0.793 | 0.053 → 0.037 | 0.000 → 0.000 | 0.000 → 0.000 | 1.156 → 2.152 | 2.890 → 2.310 |
| pdf-text-50 | 0.493 → 0.273 | 0.310 → 0.326 | 0.473 → 0.426 | 15.455 → 15.690 | 0.415 → 0.418 | 0.000 → 0.000 | 0.000 → 0.000 | 0.000 → 0.000 | 4.180 → 9.121 |
| pdf-scanned | 0.468 → 0.297 | 0.568 → 0.403 | 0.622 → 0.595 | 1.843 → 3.075 | 0.029 → 0.031 | 0.000 → 0.000 | 0.955 → 0.896 | 0.000 → 0.000 | 0.774 → 1.637 |
| pdf-diagram | 0.445 → 0.123 | unknown → unknown | 0.487 → 0.569 | 0.395 → 0.383 | 0.026 → 0.022 | 0.000 → 0.000 | 0.000 → 0.000 | 1.043 → 1.240 | 0.778 → 0.984 |

Upload timing kinds differ: before uses the server creation window; after uses measured client transfer. These values are labeled metadata, not like-for-like speed comparisons. Cached provider results can make a last-attempt stage zero even though the source has billed usage. Provider sums under concurrency are not wall time.

### Usage, costs, operations and bytes

| Fixture | Tokens before → after | Estimated USD before → after | Logical completed operations before → after | Calls in successful attempt before → after | Upload bytes | Probe skips after |
|---|---:|---:|---:|---:|---:|---:|
| plain | 0 → 0 | $0.0015000 → $0.0015000 | 1 → 1 | 1 → 1 | 115853 | 0 |
| paragraph | 0 → 0 | $0.0015000 → $0.0015000 | 1 → 1 | 1 → 1 | 119818 | 0 |
| two-label-arrow | 2628 → 2628 | $0.0040216 → $0.0025216 | 2 → 1 | 1 → 1 | 19042 | 1 |
| short-arrow-flow | 2733 → 2733 | $0.0044416 → $0.0029416 | 2 → 1 | 2 → 1 | 32183 | 1 |
| nodes | 2646 → 2646 | $0.0040936 → $0.0025936 | 2 → 1 | 1 → 1 | 16910 | 1 |
| chart | 2649 → 2649 | $0.0041056 → $0.0041056 | 2 → 2 | 1 → 1 | 11633 | 0 |
| photo-text | 2639 → 2639 | $0.0040656 → $0.0040656 | 2 → 2 | 1 → 1 | 115891 | 0 |
| table | 2654 → 2654 | $0.0041256 → $0.0041256 | 2 → 2 | 2 → 2 | 17841 | 0 |
| pdf-text-10 | 0 → 0 | $0.0000000 → $0.0000000 | 0 → 0 | 0 → 0 | 23438 | 0 |
| pdf-mixed-30 | 7983 → 7983 | $0.0094608 → $0.0094608 | 4 → 4 | 1 → 2 | 157443 | 0 |
| pdf-text-50 | 0 → 0 | $0.0000000 → $0.0000000 | 0 → 0 | 0 → 0 | 45924 | 0 |
| pdf-scanned | 0 → 0 | $0.0045000 → $0.0045000 | 3 → 3 | 3 → 3 | 261533 | 0 |
| pdf-diagram | 7983 → 7983 | $0.0079608 → $0.0079608 | 3 → 3 | 1 → 1 | 49802 | 0 |

Image OCR probes skipped: **3/8** (two-label, six-label, nodes). Logical image provider operations: **14 → 11**, excluding failures/verification HTTP reads. Image provider estimate: **$0.0278536 → $0.0233536 (16.2%)**. All 13 cases: 31915 → 31915 tokens, **$0.0497752 → $0.0452752**. No pricing-table change; excluded platform costs/free tiers are described above.

### Evidence read and first-result observation

| Fixture | Client paginated Evidence read before → after | PDF previews observed in after polling |
|---|---:|---:|
| plain | 7.673 → 1.453 | 0 |
| paragraph | 1.125 → 0.840 | 0 |
| two-label-arrow | 1.036 → 0.863 | 0 |
| short-arrow-flow | 0.940 → 0.875 | 0 |
| nodes | 0.939 → 0.886 | 0 |
| chart | 0.975 → 0.885 | 0 |
| photo-text | 1.080 → 0.869 | 0 |
| table | 0.822 → 0.933 | 0 |
| pdf-text-10 | 0.962 → 0.832 | 0 |
| pdf-mixed-30 | 1.962 → 2.376 | 4 |
| pdf-text-50 | 3.563 → 3.030 | 0 |
| pdf-scanned | 1.480 → 1.071 | 0 |
| pdf-diagram | 0.789 → 0.554 | 1 |

Client preview observations can be zero when a previously finished source is resumed; Firestore preview creation timestamps retain the actual first-result time. Processing-only preview exclusion and final publication races are tested independently. This is backend/client-script observation, **not a physical iPhone perceived-latency measurement**.

## Same-image resize experiment

All four original/2000/1600/1200px sources were sent through the Dev worker, with one-minute task schedule spacing. Each exhausted its existing four attempts with `IMAGE_AI_RATE_LIMIT` (HTTP 429). No active version/recognition was published and no OCR fallback occurred. The exact quota dimension cannot be established from the safe public error code; no Secret/provider payload was inspected.

| Provider max side | Locally prepared PNG bytes | Raw upload bytes | Attempts | Result | Usage / AI time / quality |
|---:|---:|---:|---:|---|---|
| 4032 | 97500 | 97500 | 4 | FAILED_RATE_LIMIT | unavailable |
| 2000 | 39291 | 97500 | 4 | FAILED_RATE_LIMIT | unavailable |
| 1600 | 28169 | 97500 | 4 | FAILED_RATE_LIMIT | unavailable |
| 1200 | 16030 | 97500 | 4 | FAILED_RATE_LIMIT | unavailable |

Prepared bytes are local payload-preparation measurements, not evidence that Groq accepted/billed the request. Actual usage, cost, AI completion latency, relationship accuracy and fine-text retention **cannot be compared** for these blocked requests. No extra billed replay, quota change, model change or key rotation was performed.

**Decision: retain the existing 1800px provider maximum.** Resize optimization remains unverified and is not proposed for production. Repeat this four-size quality experiment separately after rate limits recover, before considering a new bound.

## Regression, limitations and final state

- TypeScript build PASS. Domain/provider/Router/production guard suite **108/108**;
  additional offline latency safety checks **2/2**.
- Local Auth/Firestore/Storage Emulator suite **53/53**: preview ownership, lease
  change, RAG exclusion, final ordered Evidence, upload telemetry validation,
  account cleanup including missing-parent preview runs, legacy AI/quota/deletion.
- Simulator Debug build and XCTest PASS: **20 passed, 4 intentionally skipped**.
  Skips are opt-in live Dev/production fixture tests. Actual network behavior was
  validated by the separate Dev REST benchmark, not those skipped XCTest cases.
  Swift optional metadata/old-source decoding and the actual partial result view
  are covered locally.
- Eight images + five PDFs, both reference/optimized runs: **26/26 PASS**. Each
  real run validates Unit/checkpoint → stored chunks → Evidence → paginated
  retrieveContext body/locator equality. Between before and after, all 13 bodies
  and routes match exactly. Unit failures/checkpoints have no OCR fallback.
- 30-page mixed PDF is 26 native / 1 OCR / 3 AI before and after. Optimized live
  provider spans show peak 2; AI cap 2/OCR cap 3 is enforced in tests. Current-attempt
  PDF page times may include historic cached page measurements and waiting for a
  provider slot; a cached page's maximum can exceed the current attempt wall time.
- Text-only native 10/50 benchmarks use PDF pages with a white vector background.
  Guarded vector inspection therefore still renders these pages; do not claim zero
  renders in these actual cases. A separate 10-page no-vector native test proves
  zero render/OCR/Qwen. Route precision takes precedence over skipping vector inspection.
- The six-label successful worker is **4.401s → 3.376s (-23.3%)**; source-to-ready
  **6.464s → 5.472s (-15.3%)**. OCR probe is skipped; Qwen tokens 2733 and final text
  are unchanged. Estimate **$0.0044416 → $0.0029416 (-33.8%)**.
- Mixed-30 successful worker is **9.997s → 8.283s (-17.1%)**; source-to-ready
  **69.738s → 61.773s (-11.4%)**. First native preview was stored at **3.413s** after
  creation, before the whole PDF was ready. The sequential reference also included
  preview instrumentation (3.493s), so this is preview availability, not a measured
  95% before/after UI speedup. The previously deployed UI waits for final ready.
- Groq 429 occurred. Benchmark attempts beyond the first: **9 before / 7 after**.
  Diagram-heavy final-ready remains about 226s with four attempts; concurrency does
  not remove the provider backoff bottleneck. Several images were slightly slower
  in the successful-attempt measurement. N=1 and differing caches/rate limits do
  not justify claiming every case is faster.
- Finite after queue waits range **262–1311ms**; five retry cases have unknown queue
  wait. First post-update image preparation was 2073ms, later preparations about
  407–595ms. Infrastructure cold start is not established, and no minInstances,
  CPU/memory, imports, or queue settings change is proposed.
- UI polling now adds at most its current 1/2/3s interval before the next refresh,
  plus network/read time; the obsolete extra 3s after an already-ready response is
  removed. Real physical iPhone perceived latency is **not measured this turn**.
  Confirm processing previews/page headers and final route/text with a Dev internal
  build, and check that partial text cannot be retrieved as a complete source.
- Dev-only source updates touched four Functions; worker was updated for the
  instrumented reference and optimized versions. Full installed source/config and
  protected state passed. No env, Rules/index, IAM, Secret, allowlist, sharing,
  lifecycle, Scheduler settings, or production resource was changed.
- The single synthetic Dev Auth account was deleted. The existing paginated cleanup
  stopped after 25 sources; the same helper was explicitly continued for this owner
  only. **All 30 sources (26 successful + 4 rate-limited), nested/missing-parent runs,
  previews, raw/derived objects and usage were cleaned.** Minimal deletion tombstones
  remain intentionally. No global sweep or other account was touched. Dev queue is
  RUNNING and empty; Scheduler configuration is unchanged. Temporary local OAuth
  credential used by the existing SDK helper was deleted; no SA key was created.
- Private UID/credential scan of changed and new source/docs found **zero findings**;
  no private configs/evidence are tracked or staged. An unchanged baseline tracked
  `scripts/__pycache__/scrape_syllabus.cpython-310.pyc` is unrelated and retained.

### Changed source files

Swift: `Aogaku/AIInput/AIDetectionResult.swift`, `AIDetectionResultView.swift`,
`SourceIngestionService.swift`, `SourceModels.swift`,
`Aogaku/CourseDetailViewController.swift`, `AogakuTests/AIDetectionResultTests.swift`.

Functions: `functions/src/ai/index.ts`, `visualExtraction.ts`, new `latency.ts`,
`localVisual.ts`, `progressive.ts`; optional type fields only in `pricing.ts` and
`visualRouter.ts`. Tests: `functions/test/emulator.test.cjs`, `visual-router.test.cjs`,
new `visual-latency.test.cjs`.

Operators/docs: new `scripts/visual_latency_dev.cjs`, `visual_latency_benchmark.cjs`,
`visual_latency_fixtures.cjs`, `visual_latency_resize_dev.cjs`,
`visual_latency_cleanup_dev.cjs`, `visual_latency_report.cjs`,
`visual_latency_review.cjs`, `test_visual_latency_safety.cjs`;
`scripts/test_production_recognition_review.cjs` retains archived-artifact rejection
while testing that a fresh expanded review is required; this document.

### Git state

HEAD remains `b3a04d1d7d0cf47f76199c4b46b3451adc795dc5`; branch unchanged.
All task changes are unstaged/uncommitted. No commit, push, merge or new branch.
The build-generated tracked `functions/lib/index.js` was restored to its baseline
content; generated AI modules remain ignored. Source changes are preserved.
Existing personal `Aogaku.xcscheme` Debug→Release edit and untracked
`scripts/__pycache__/firebase_dev.cpython-311.pyc` are preserved and excluded from
this feature. No `Aogaku-clean` change. Production rollout is **awaiting approval**;
resize quality remains an uncompleted optional experiment, so the 1800px setting stays.

## Approved production rollout (2026-10-09)

`scripts/deploy_production_visual_latency.cjs` targets only `aiProcessSource`,
`aiCompleteSource`, `aiGetSource`, and `aiGetEvidence`, with
`updateMask=buildConfig.source`. Each original installed ZIP is archived privately.
Exactly five runtime modules change/add; original entry points/package files and
all other modules remain intact. Full-source checks cover all 25 Functions.
No source/env/IAM mutation is retried. Approved bounded retries cover only reads.

Preflight requires RUNNING queue, paused Scheduler, unchanged live pilot cohort,
sharing OFF, database/rules/indexes/Secrets/lifecycle/IAM equality to the prior
verified state, and fresh full deployed source manifests. Queue PAUSE is followed
by zero active dispatches/source leases. The four updates run sequentially;
operation completion and installed full source/config/protected-state verification
precede the next update. Any deployment/protection error stops with queue PAUSED,
without rollback. Resume requires all post-checks and admission checks to pass.

`production_visual_latency_auth.cjs` performs 18 live anonymous/pilot admission
checks and 9 nonpilot domain checks using exact installed source/live environment
with network forbidden. It creates no Auth accounts, allows no new UID and writes
no AI fixtures. Domain checks are not claimed as a new live nonpilot-token test.

`production_visual_latency_e2e.cjs` creates eight fresh synthetic sources solely
for an already allowed pilot: four image types, 10-page native text PDF, 30-page
mixed PDF, scanned PDF and diagram PDF. It verifies final selected Unit, chunks,
Evidence, retrieval and locators; live progressive preview RAG exclusion; native/
OCR/AI routing, provider usage/cost, diagram probe skip, bounded concurrency,
default DB isolation, old OCR immutability and direct-client access denial.
Private sources, registry, full Evidence/provider metadata, ZIPs, tokens and binary
fixtures remain under ignored `build/`. Private sanitized API mirrors used by
UIKit XCTest also remain ignored. They are never included in the commit.

Physical-device validation uses the ordinary `Aogaku` Scheme internal Release
build with the production bundle ID. The unrelated existing shared Scheme
LaunchAction edit is excluded from the feature commit. Synthetic PDFs in the app
Documents container let the operator confirm “途中結果・検索対象外”, page order,
final transition, Router/provider/model and latency diagnostics without real
course materials. Commit/push follows successful backend and device validation.

### Production verification outcome

The approved four source-only updates passed installed full-source and protected
state checks. Other 21 Functions, live pilot cohort, sharing, Scheduler, Rules,
indexes, IAM, Secrets, lifecycle and resource sizing/rates remain unchanged.
Queue was restored to RUNNING after all checks; Scheduler remains PAUSED.

Eight fresh production synthetic inputs passed. Plain/paragraph images chose OCR;
two-label/six-label connectors chose Qwen with zero OCR probes. PDF routes were:
10-page text all native, 30-page mixed native=26/OCR=1/AI=3, three scanned pages all
OCR, three diagram pages all AI. The mixed PDF matched the sequential Dev reference
on all 30 final page text hashes and locators, and the complete route array; fixture
bytes also matched. Unit/chunks/Evidence/retrieval adoption remained identical.

Mixed PDF first server preview: **5.629s** (earliest page across all attempt runs);
first client observation: **11.296s**; source-to-ready: **94.609s**. It needed two
worker attempts; the successful attempt wall was 20.059s with 28 checkpoint hits.
Diagram PDF needed three attempts. Worker logs during this rollout contained six
`IMAGE_AI_RATE_LIMIT` error entries; this count is not six unique HTTP requests
and includes the validation interval. All inputs completed via normal guarded
retry/checkpoint reuse; no OCR fallback or operator mutation retry occurred.
Provider spans confirmed AI peak=2 and OCR peak=2, within reviewed caps 2/3;
page-job cap 4 was verified in the installed module and bounded-jobs tests.

Both processing preview RAG exclusion and ready publication were verified.
Old OCR sources were read without changes; direct named Firestore/raw Storage
requests were rejected for anonymous and pilot client tokens. The ordinary
Aogaku physical-device preview/final/metadata display was confirmed by the user.
UIKit XCTest additionally renders private mirrors of the actual production API
responses. Partial latency may be absent until completion; unknown values remain
unknown, rather than becoming invented zeros.

Six-label connector measured 2,733 tokens, estimated provider cost $0.0029416,
worker 5.469s, OCR probe 0, AI 1.075s, persistence 2.346s, startup 0.671s,
Router 0.183s and queue wait 0.330s. Concurrent sums and final-attempt timing are
not a substitute for full source-to-ready duration including backoff.

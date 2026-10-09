# Production Visual Router migration

対象は既存pilot限定の `forta-aogaku`、named Firestore `aogaku-ai`。2026-10-09の明示承認に基づくsource-only移行。内部UID、token、source ZIP、provider response、原本、production evidenceはGitに保存しない。

## Contract

- 新規PDF: `pdf-auto-v1`。ページごとに `native_text` / `vision_ocr` / `multimodal_ai` を選ぶ。
- 新規画像: `image-auto-v1`。単純文字はVision、図・関係・複雑layoutはQwen。OCR probeと最終OCR routeは別概念。
- AI: `groq / qwen/qwen3.8-27b`。検証済みsystem-priority Grounded promptを使い、providerの`finalText`だけをUnitとして採用する。AI失敗をOCRへfallbackしない。
- 音声: `audio-groq-v2 / whisper-large-v3-turbo`、時間課金。メモは従来方式。
- selected Unitだけからchunksを作り、EvidenceとretrieveContextは同じactive runの本文・locatorを返す。
- ready状態の旧OCR/image-ai-v2資料を再処理しない。UIは実pipelineVersionを表示し、欠損時に新方式を推測しない。

## Ten-function migration scope

`aiProcessSource` → `aiGetSource` → `aiGetEvidence` → `aiRetrieveContext` → `aiRetrySource` → `aiUpdateSource` → `aiDeleteSource` → `aiCompleteSource` → `aiCreateSource` → `aiListSources`。

1. 最新25 Functionsのmetadata/full installed source/env/IAMと、DB/Rules/indexes/Secret metadata/lifecycle/queue/Schedulerを取得する。
2. 直前成功状態からのdriftがない場合だけqueueをPAUSE。dispatch数・source leaseとも0を確認後、fresh artifactを作る。
3. 1件ずつfresh staging→source-only PATCH→operation→full source一致→protected-state確認。mutationを再試行しない。
4. 全25 sourceを照合。27 live Auth gate checksと、実稼働source・live envの9 nonpilot domain gatesを確認する。
5. 全件PASS後だけqueueを元のRUNNINGへ戻す。SchedulerはPAUSED、sharing OFF、pilot allowlist・App Checkは不変。
6. 新しい合成資料だけで本番E2E。非pilot Auth accountは別承認された1件だけを作り、拒否確認後に削除する。

実装は `deploy_production_visual_router.cjs`、`production_visual_router_{domain_gates,auth,e2e,assets}.cjs`。read-only transient retryは既存 `production_read_retry.cjs` を利用する。実行journalとapprovalはignored `build/production-visual-router-20261009/` に置く。過去approval・baselineの再利用やUNKNOWN mutationの再送は拒否する。このoperatorを次回移行にそのまま再実行しない。

## Verification and cost

3ページの新規合成PDFはnative文字・スキャン文字・5矢印図、画像は文字主体と同じ5矢印図。Unit checkpoint→Firestore chunks→Evidence→retrieveContextの完全一致を検証し、本番返却fixtureを実際のUIKit検出結果Viewで表示するXCTestへ渡す。raw Groq responseを別採取したという主張はせず、稼働parserとprovider後checkpointを根拠とする。

Qwenは実usageを保存し、既存pricing configでinput/outputを計算。OCRはstandard paid-tierのunits推定で月次無料枠・量割引・インフラ費用を含まない。nativeページのLLM token/AI costは0。Whisperは最低課金時間を反映した音声時間ベースで、token課金として表示しない。

## Rollback

自動rollbackは行わない。途中の失敗・drift・source mismatchならqueueをPAUSEDのまま停止し、成功済みrevisionとoperationを報告する。rollbackは別承認・fresh preflightを経て、保存済みbefore sourceを10件すべて同じ旧contractへsource-only更新し、full source/env/IAM/保護設定の照合後にだけqueueを復旧する。Rules、IAM、Secret、allowlist、Scheduler、既存資料へ追加変更しない。

新しいauto-route receiptが既にある場合は、旧workerが対応しないreceiptを実行しない。対象sourceの処理可能性を事前に確認する。旧ready資料の一括再処理でrollbackしない。

## Physical-device follow-up

通常 `Aogaku` SchemeのRelease内部buildを接続iPhoneへインストール・起動し、利用者が通常の時間割画面を確認済み。外出に伴う追加指示により、物理iPhoneの新規送信→検出結果の最終確認はbackend完了条件から外す。

後日、既存pilotで通常Aogakuを開き、授業のAI入力から合成PDF/文字画像/矢印図を送る。検出結果で`Pipeline: pdf-auto-v1` / `image-auto-v1`、本文、token/cost、ページ別処理情報を確認する。実機未確認をPASSに含めない。

## Final audit

本番E2E・最終protected audit完了後に結果を追記する。commit/push対象はsource、tests、scripts、非機密docsのみ。既存の通常Aogaku SchemeのローカルRelease変更とpycacheは本タスクのcommitに含めない。


2026-10-09: ten-function source migration and its protected post-checks are
installed. The follow-up connector fix updated only aiProcessSource revision
00005 -> 00006. Queue was restored RUNNING after all source/protected/Auth
checks. Five fresh connector E2E inputs and text/locator propagation pass, but
the final legacy guard stopped on JSON map ordering. Read-only diagnosis found
no actual legacy change; final E2E is not COMPLETE. See image-router-connectors.md
for the exact safe-stop/resume scope. No commit/push occurred at this stop.


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


## 保存前の最終ローカル検証

- TypeScript build PASS。
- domain / recognition / Router / Phase5a / revision / read-only retry / deploy
  guardなどNode回帰100/100 PASS。
- real local Firestore/Storage Emulator: 51/51 PASS。demo project固定、
  named/default Rulesを別々に読み込み、実クラウドへ接続しない。
- prompt selector Python tests: 3/3 PASS。
- offline Simulator Debug build/XCTest成功: 23件中19 PASS、4 skip、失敗0。
  skipは3件のnetwork opt-inテストと未生成のprivate production UI fixture。
  実機の正常動作は利用者が確認済みとの報告に基づく。
- 本番read-only audit: queue RUNNING、Scheduler PAUSED、sharing OFF、
  live pilot allowlistと保護metadata不変。今回のproduction mutationは0。
- staged source/test/script/docのsecret/private UID scan PASS。

## この保存に含めるファイル一覧

- `Aogaku/AIInput/AIDetectionResult.swift`
- `Aogaku/AIInput/AIDetectionResultView.swift`
- `AogakuTests/AIDetectionResultTests.swift`
- `docs/ai-input/evidence-adoption.md`
- `docs/ai-input/evidence-grounding.md`
- `docs/ai-input/image-router-connectors.md`
- `docs/ai-input/production-visual-router-rollout.md`
- `functions/src/ai/recognition.ts`
- `functions/src/ai/visualExtraction.ts`
- `functions/src/ai/visualRouter.ts`
- `functions/test/emulator.test.cjs`
- `functions/test/recognition.test.cjs`
- `functions/test/visual-router.test.cjs`
- `scripts/deploy_detection_dev.py`
- `scripts/deploy_production_image_router.cjs`
- `scripts/deploy_production_visual_router.cjs`
- `scripts/evidence_adoption_dev.cjs`
- `scripts/evidence_prompt_dev.cjs`
- `scripts/image_router_dev.cjs`
- `scripts/image_router_fixtures.cjs`
- `scripts/production_image_router_auth.cjs`
- `scripts/production_image_router_e2e.cjs`
- `scripts/production_image_router_review.cjs`
- `scripts/production_visual_router_assets.cjs`
- `scripts/production_visual_router_auth.cjs`
- `scripts/production_visual_router_domain_gates.cjs`
- `scripts/production_visual_router_e2e.cjs`
- `scripts/test_deploy_production_image_router.cjs`
- `scripts/test_evidence_adoption_dev.cjs`
- `scripts/test_evidence_prompt_dev.py`
- `scripts/test_image_router_dev.cjs`
- `scripts/test_production_image_router_review.cjs`
- `scripts/test_production_recognition_review.cjs`
- `scripts/test_production_visual_router_deploy.cjs`
- `scripts/test_production_visual_router_e2e.cjs`
- `scripts/visual_router_dev.cjs`

# 本番Recognition pipeline反映結果（2026-10-08）

状態: `DEPLOY_COMPLETE_PILOT_INPUTS_PASS_NONPILOT_LIVE_PENDING`。
承認済み10 Functionsの更新、保護リソース監査、本番4入力の処理は成功。有効な本番非pilot Authトークンによる拒否試験だけ、使い捨てAuthアカウントの追加作成承認を待っています。実ユーザーや新規Authアカウントを無断使用していません。

## 本番変更

対象 `forta-aogaku` / `505828754933`、bucket `forta-aogaku.firebasestorage.app`、Release Bundle ID `com.forta2k25.Aogaku` をfresh preflightで照合。
開始時のqueueは前回停止によるPAUSED。drain（dispatch 0 / active source lease 0）確認後、下記10件を1件ずつ `buildConfig.source` のみPATCHしました。mutationの自動retryなし。全件ACTIVE、Node22、東京、runtime SA / trigger / environment / Function・Run IAMは不変。全post-check成功後、queueを元のRUNNINGへ1回復旧しました。

| Function | before revision | after revision | full source / env |
|---|---|---|---|
| aiCompleteSource | aicompletesource-00003-sen | aicompletesource-00004-nuf | PASS |
| aiCreateSource | aicreatesource-00003-jid | aicreatesource-00004-sop | PASS |
| aiDeleteSource | aideletesource-00003-ciw | aideletesource-00004-jeq | PASS |
| aiGetEvidence | aigetevidence-00003-xus | aigetevidence-00004-foc | PASS |
| aiGetSource | aigetsource-00003-giq | aigetsource-00004-yem | PASS |
| aiListSources | ailistsources-00003-xeq | ailistsources-00004-muw | PASS |
| aiProcessSource | aiprocesssource-00003-mep | aiprocesssource-00004-pig | PASS |
| aiRetrieveContext | airetrievecontext-00003-vut | airetrievecontext-00004-fem | PASS |
| aiRetrySource | airetrysource-00003-duj | airetrysource-00004-sen | PASS |
| aiUpdateSource | aiupdatesource-00003-law | aiupdatesource-00004-lur | PASS |

全10件のfull source manifestは `2061dbc03d0a6470879d185ee5ed85cd220bca5040d976a71717db1228ff1d56` と一致。beforeは `34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`。最終監査で全25件のinstalled sourceを照合し、対象外15件（legacy13 + background2）のsource / metadataは不変でした。

## 本番synthetic E2E

既存pilotだけで新規メモ1、画像2、PDF1、音声1を作成。実ユーザー資料・個人情報・実録音は使用していません。

| 入力 | 結果 | 処理・Evidence |
|---|---|---|
| メモ | PASS | ready / list / Evidence / retrieve context / chunks |
| 画像1 | PASS | Groq Qwen / AI-only、807ms、input 1,969 / output 50 / total 2,019 tokens、推定 $0.0017752 |
| 画像2 | PASS | Groq Qwen / AI-only、783ms、input 1,969 / output 81 / total 2,050 tokens、推定 $0.0018992 |
| PDF | PASS | 1ページ目本文抽出、2ページ目OCR、ページ番号付きEvidence / chunks / retrieval |
| 音声 | PASS | Whisper Turbo、12.348秒、2,322ms、推定 $0.0001372、時刻付きEvidence / chunks / retrieval |

新規画像2件は `provider=groq` / `model=qwen/qwen3.8-27b` / `method=multimodal_ai` / `pipelineVersion=image-ai-v2`。Groqレスポンスの実usageでtokenを保存。input $0.80、output $4.00 / 100万tokensの設定で推定USD費用を保存。pricingAsOfは2026-10-08。Google / Apple OCRへのfallbackなし。Qwen失敗はretryable error。

音声は `whisper-large-v3-turbo` / `groq_asr` / `audio-groq-v2`。tokenはnull、時間課金として保存。検出結果UIでは「音声認識はtoken課金ではないため対象外」と表示。成功後の音声原本削除は従来の正常仕様です。

AI content / chunks / usageはnamed DB `aogaku-ai`、授業catalogは(default)参照。5桁class ID、syllabus URLのYR、年度snapshotを維持。defaultへのAI本文・chunks・usage書き込みなし。旧OCR資料は既存Evidenceを閲覧でき、source / chunksの更新時刻と本文は変更されていません。既存OCRの再処理なし。同一clientRequestIdの重複受付で同じsourceが返ることも確認。

## 認証・安全状態

- 既存pilot **2件**を全10 Functionsでそのまま維持。値は本書・ソースへ記載しません。
- live anonymous9 / pilot admission9、計18 checks PASS。
- exact installed source + 実production envで非pilot UID gate9件 PASS（データ・Storage・provider IOなし）。これは有効な本番非pilot Authトークンでの実通信試験の代替完了判定ではありません。
- live client direct Firestore / Storageは匿名・本人とも403（4 checks PASS）。
- 本番非pilot Auth実通信は追加承認待ち。アカウント作成・削除はまだ実行していません。
- queue RUNNING、Scheduler PAUSED、sharing OFF。一般ユーザー開放なし。
- Rules / indexes / IAM / Secret metadata・version / lifecycle / Eventarc / service account keysは不変。Secret payload取得なし。Remote Config / App Check enforcementへの操作なし。

## ローカル検証・UI

production deploy/review、domain、recognition、Phase5a/revision guard等のローカル回帰54/54 PASS。Simulator Debug buildと検出結果XCTestは12 PASS / 1 Devネットワークopt-in SKIP / 0 FAIL。実本番のsynthetic Qwen / Whisper Evidenceを取得し、オフラインSimulatorでprovider / model / 最終Evidence / token / cost表示を検証しました。実機の通常Aogaku Schemeからの手操作アップロードは今回のCLI E2Eに含みません。

## テスト側の修正と停止記録

本番Functionの更新失敗・contract不整合・source mismatchはありません。E2E harnessの2つの誤った判定（成功時に削除される音声原本の存在要求、Firestore REST field順序に依存するJSON hashと旧APIのactiveVersion比較）を既存結果のread-only検証で解消。停止時registryを保持し、再upload / provider再処理 / Function再更新はしていません。rollback不要でした。

## 保存・cleanup

fresh fixture5件の所有権registry、認証情報、metadata、approval、audit evidenceはignored `build/production-recognition-deploy-20261008-resume1/` に保存。Gitへ含めません。資料は内部確認用として保持し、cleanup時はregistryとownershipを照合して当該synthetic資料だけを削除する別操作とします。音声原本のみ正常処理で自動削除済み。

本ターンで調整したローカルファイル: `scripts/deploy_production_recognition.cjs`（fresh resume / queue drain / source・protected-state guard）、`scripts/production_recognition_e2e.cjs`（入力・権限試験とread-only復旧検証）、`scripts/production_recognition_auth.cjs`（追加承認必須の使い捨てAuth harness、未実行）、`scripts/test_production_recognition_deploy.cjs`、`AogakuTests/AIDetectionResultTests.swift`、本書。以前からの変更は保持。

commit / push / merge / App Store公開 / Phase5bは実行していません。通常Aogaku Schemeの既存ローカル差分も変更せず保持しています。

# 新規画像がVision OCRになる原因と修正（2026-10-08）

## 原因

利用Schemeはユーザー確認により `Aogaku`。現在のLaunchActionはRelease。`AppBackend.configureFirebase()` はReleaseでproduction設定を読み、通常アプリと同じ本番projectへ接続する。ローカルのQwen実装はDevだけへ反映済みで、本番への今回の変更はない。Phase 5a基点 `927a3d6` の実装では画像workerの `extractImage` が直接 `documentTextDetection` を呼び、`vision_ocr` chunksを保存する。ローカルSwift更新だけではデプロイ済みworkerは切り替わらない。

以前の検出結果UIはrecognition metadataがなくchunk methodが `vision_ocr` なら一律「Google Vision OCR（既存資料）」と表示していた。「既存資料」は作成時期の判定ではなく、旧処理結果の判定だった。そのため本番の旧workerで新規画像を処理した場合もこの表示になった。feature flag/Remote ConfigでQwen失敗をOCRへfallbackする分岐は現在の新実装にはない。これは接続先・デプロイ版の差である。本番は今回readもdeployも行わず、保存済み基点コードとScheme設定から確認した。

## 修正

- iOSは新規/未完了画像送信前に `aiListSources` の `inputCapabilities.image` を取得し、provider/model/method/pipelineVersion/fallbackを照合。旧APIや未対応APIではcreateもbinary uploadもしない。送信前の元画像はLocalSourceStoreに残り、後で再送可能。通常Schemeの本番接続先は変更しない。
- image作成receiptの `sourceType=image` と `pipelineVersion=image-ai-v2` も検証し、旧作成APIと新workerが混在する場合もbinary uploadを拒否。
- Functionsは画像を `extractImage` → Groq Qwenへ固定。provider返却modelが一致しなければretryable `IMAGE_MODEL_MISMATCH`。checkpointもprovider/model/method/pipelineVersion/unit methodを検証し、OCR混入ならretryable `IMAGE_PIPELINE_MISMATCH`。silent fallbackなし。
- 正式providerは `groq`、modelは `qwen/qwen3.8-27b`、methodは既存v2契約を維持した `multimodal_ai`、pipelineは `image-ai-v2`。
- UIは実metadataから `Groq / qwen/qwen3.8-27b` と表示。v2 sourceにOCR chunksや不完全metadataが返った場合はQwen結果として表示しない。旧 `input-v1` OCR Evidenceは従来どおり読み出し、表示は「Google Vision OCR（保存済み結果）」へ変更。既存資料の再処理なし。
- PDFのVision OCR fallback、音声Turboルート、既存アカウント削除は変更しない。

## Dev実通信結果

新たに作った架空資料画像2枚。run UUIDを画像pixelsにも入れ、異なる内容・異なるSHA256で重複receiptの再利用を回避。新規anonymous Dev UIDを使用、既存catalog fixtureだけ参照。旧E2E registryと結果を上書きしない。

| 新規画像 | provider/model | 入力 | 出力 | 合計 | 推定USD | provider処理 |
|---|---|---:|---:|---:|---:|---:|
| 植物の成長図 | Groq Qwen 3.8 27B | 1969 | 50 | 2019 | 0.0017752 | 1.065秒 |
| 検索拡張生成図 | Groq Qwen 3.8 27B | 1969 | 82 | 2051 | 0.0019032 | 0.741秒 |

両方 create(image-ai-v2) → signed PUT → complete → Task worker → Groq → ready → chunks/Evidence → retrieve context PASS。recognition mapをnamed `aogaku-ai`で確認、defaultの同source pathは404。全chunks methodは `multimodal_ai`。新画像extractorにVision/Apple呼び出しがなく、EmulatorではGroq以外のprovider transportを拒否している。

画面表示例（新規画像1の実測値）:

```
Groq / qwen/qwen3.8-27b ・ 1.1秒
Token: 入力1,969 / 出力50 / 合計2,019 tokens。
Cost: 推定処理コストは $0.001775です。
料金基準: 2026-10-08・請求額ではありません。
```

## 検証

- TypeScript build PASS、domain + recognition 24/24 PASS。
- 実named/default Firestore + Storage Emulatorの削除/権限/旧AI/quota/新画像/音声回帰49/49 PASS。
- Phase4/Phase5a/revision/read-only retryの実行可能guard 20/20 PASS。追加の過去execution journal依存テスト4件はこのコピーにprivate `build/production-phase4/execution.json` がないため実行不能。秘密証跡は捏造・移植しない。
- Simulator Debug build/XCTest 12件: 11 PASS、Dev login/送信opt-inテスト1 SKIP、失敗0。今回Dev実画像2枚のEvidence/usage/costを実カードに表示するXCTestはPASS。
- 最初のsandbox内Xcode/CLIのキャッシュエラーはローカル権限で再実行して解消。Emulator最終CLI終了コード0。
- Devの `aiListSources` / `aiProcessSource` だけdeploy。2件ACTIVE、runtime/SA/業務env/Secret binding維持、各8 source/compiled filesをSourceCodeGetで照合。更新対象外15 Functionsのmetadata/updateTime完全不変。queue RUNNING、lifecycle不変。
- CLIがaiListSourcesの生成済み `FUNCTION_SIGNATURE_TYPE=http` markerを省略。Functions Frameworkの既定httpであり、Callable実通信で正常動作を確認。業務envは不変。この差だけをpost-checkで明示許容し、他env driftは拒否。

## 現在の確認方法と本番反映

Devの通常アプリで試すにはXcode `Aogaku-Dev` Schemeを使用。`Aogaku-AI-Dev-E2E` は自動テスト用。`Aogaku` は本番のまま。修正版clientは未対応本番へ新規画像を送らず、バックエンド更新が必要と表示する。本番でQwenを使うには別承認による本番artifact作成・対象Functions更新が必要。creation/list/source/Evidence応答とworkerのv2 metadata契約を同時に揃え、既存pilot/sharing OFFを保持して内部E2Eする。今回そのdeployは行わない。

Dev fixture/anonymous Auth/原本/derived/chunksは調査用に保持。`build/image-route-dev-e2e/registry.json` はprivate、mode0600、Git除外。cleanup時はこのregistryのownershipを確認し、今回作成したものだけ対象にする。既存fixture/実資料は触らない。表示用のtokensなし匿名UIDなしfixtureは `AogakuTests/DevFixtures/image-route-dev-results.json`、同じくGit除外。

## 今回の変更ファイル

- Aogaku/AIInput/AIDetectionResult.swift
- Aogaku/AIInput/AIDetectionResultView.swift
- Aogaku/AIInput/SourceModels.swift
- Aogaku/AIInput/SourceIngestionService.swift
- AogakuTests/AIDetectionResultTests.swift
- functions/src/ai/pricing.ts
- functions/src/ai/recognition.ts
- functions/src/ai/extractors.ts
- functions/src/ai/index.ts
- functions/test/recognition.test.cjs
- functions/test/emulator.test.cjs
- scripts/deploy_detection_dev.py
- scripts/image_route_assets.swift
- scripts/image_route_dev_e2e.cjs
- scripts/audit_image_route_dev.cjs
- docs/ai-input/IMAGE_AI_ROUTE_FIX.md
- docs/ai-input/DETECTION_RESULTS.md（今回レポートへの案内追加）

参考: [正式Groqモデル](https://console.groq.com/docs/model/qwen/qwen3.8-27b)、[Functions Framework default HTTP](https://github.com/GoogleCloudPlatform/functions-framework-nodejs/blob/main/src/options.ts)。

# Visual Router v1 — 実装・Dev検証・本番移行レビュー

2026-10-09。branch `codex/ai-recognition-comparison-lab`、基点 `c939661c5c1fba0314b8cb58f6b786b421a81b39`。本番アクセス・deployは未実施。通常Aogaku Schemeの既存Debug→Releaseローカル差分はcommit対象外として保持する。

## Architecture / データ境界

新画像は `image-auto-v1`、新PDFは `pdf-auto-v1`、source `schemaVersion=5`。音声 `audio-groq-v2` とメモ `input-v1` は変更しない。ready / partial_ready の旧資料はworkerのterminal判定で再実行せず、保存済みOCR / Qwen / 音声Evidenceを読む。

PDF → PDF.jsページ解析 → ページ単位 native_text / vision_ocr / multimodal_ai → 最終Unit（pageNumber） → active-run chunks → evidence / retrieve context。

画像 → 正規化PNG → Google Vision DOCUMENT_TEXT_DETECTIONの軽量OCR・layout probe → vision_ocr / multimodal_ai → 最終Unit（imageIndex） → chunks。画像のprobeも課金対象として記録し、OCRを選んだ場合はその結果を再利用する。明確な図のPDFはprobeを省いて直接AIへ送る。native PDFはOCR/LLMを呼ばない。

PDF.jsの実canvasレンダラー（@napi-rs/canvas 1.0.10を明示依存）を使い、画像・描画・文字の位置関係を含む元ページをQwenへ送る。文字だけの画像を再生成して図を落とす方式は使わない。50ページ上限、render最大辺1800px、ページ逐次処理、90秒render timeout、巨大operator/text list制限。各ページ処理はcancel/fence確認で保護する。

授業catalogは明示(default)、AI source / runs / chunks / usage / owner / offeringsは明示`aogaku-ai`。年度＋5桁ID、syllabus YR一次情報、snapshot/localCourseUUIDは既存仕様を維持。databaseを跨ぐtransactionなし。Firestore collection / indexes / Rules追加なし。

## 判定signal / 初期閾値

`nativeTextLength, nativeTextQuality, textCoverage, textBlockCount, imageCoverage, drawingCount, drawingScore, blockDispersion, readingOrderPenalty, nonTextCoverage, lineScore, relationMark, ocrCharacterCount, ocrQuality, probeAvailable`。

textQualityは空白除外30文字で1.0、文字化け/controlを減点。native / OCR品質閾値0.78。OCR品質はVision confidence×textQuality。OCR confidenceだけでrouteを決めない。

```
semanticImage = nativeTextLength > 0 ? imageCoverage : imageCoverage * nonTextCoverage
visualComplexity = clamp(
  semanticImage       * 0.10 + blockDispersion     * 0.15
  + drawingScore      * 0.20 + readingOrderPenalty * 0.15
  + nonTextCoverage   * 0.20 + lineScore            * 0.20)
```

全ページスキャンのbitmap面積だけでは図と判定しない。一方、部分的な埋め込み画像は図の手掛かりとする。PDFの背景・glyph描画を図と誤認しないため、native text box外の実pixelも確認する。画像はVision word box外のinkと水平/垂直/斜線を解析。罫線・軸・長いconnector、明示矢印、nativeと画像の混在が意味理解のsignalになる。

override: explicit relation mark→score≥0.85、lineScore≥0.5→≥0.60、semantic drawingScore≥0.5→≥0.60、埋め込み画像面積≥0.12（本文あり又は全面scanでない）→≥0.55、nonTextCoverage≥0.35→≥0.55。

score <0.30: native品質が十分ならnative、それ以外でprobe品質が十分ならOCR。0.30〜0.55:曖昧なのでAI。≥0.55:AI。品質不足もAI。これは初期heuristicであり、未見資料に対する完全な意味分類を保証するものではない。数値と理由を残し、今後の誤判定から調整できる。

## Provider / 失敗・再送

AI: provider `groq`, model `qwen/qwen3.8-27b`, unit method `multimodal_ai`。Vision: provider `google_vision`, model `DOCUMENT_TEXT_DETECTION`, method `vision_ocr`。native: `pdfjs` / `native_text`。

AI選択後にprovider 429/5xx、JSON契約不一致、モデル不一致が起きたらretryable failure。Google/Apple OCRへsilent fallbackしない。selected AIが失敗したPDF全体を成功扱いにしない。完成ページ・compact OCR probeはversion別Storage checkpointへ保存し、再送で再利用。新Router失敗を旧image-ai-v2 recognitionとして表示しない。

provider呼出し直前にquota reserve / account-active確認、checkpoint保存とpublish時にlease / deletion fence確認。既存削除・task cancellation・遅延upload/workerの拒否経路を再利用する。

## Metadata / UI

sourceおよびrun recognition:

```
provider / model / method=auto_route / pipelineVersion / processingMs
inputTokens / outputTokens / totalTokens / estimatedCostUSD / pricingAsOf
routing.routerVersion=visual-router-v1
routing.pages[]:
  pageNumber 又は imageIndex
  route / provider / model / routingScore / routingReason[]
  nativeTextQuality / ocrQuality / visualComplexity / features{...}
  inputTokens / outputTokens / totalTokens
  aiCostUSD / ocrCostUSD / estimatedCostUSD / ocrUnits / processingMs
routing.counts{native_text,vision_ocr,multimodal_ai}
routing.ocrUnits / aiCostUSD / ocrCostUSD / pricingAssumption
```

Firestoreへprovider raw JSONやVision annotationを保存しない。Evidenceは最終本文だけ。OCR text/必要boxesのcompact probeはprivate derived Storageへ保存する。page番号とmethodはchunksに保持し、UIは[p.n]区切りで本文を統合する。

資料全体はnative/OCR/AI内訳、実測LLM tokens、OCR probe回数、AI+OCR cost、processing timeを表示。Debug（又は内部Release起動env AOGAKU_ROUTER_DIAGNOSTICS=1）ではページ別score/reasonを表示。modelのない旧資料にモデル/利用量を捏造しない。新RouterのEvidenceはmetadataとlocator/methodを照合して表示する。

## 料金 / 比較の限界

Qwenは実usageからinput×$0.80/1M + output×$4.00/1M。画像tokenizationを独自推算しない。native/OCRのLLM tokensは0。usage未取得はunknown/nullであり、0として成功表示しない。

Vision DOCUMENT_TEXT_DETECTIONは標準有料帯$1.50/1000units（各画像／PDFページ）。月初1000units無料、5M超$0.60/1000のtierもconfigに記録。プロジェクトの月間請求単位残量を取得していないため、UIのOCR estimateは標準有料単価で算出し、その前提を明記する。probe→AIでもOCR分を必ず足す。実請求額、infra、失敗した課金済み呼出し、retry全体の費用は保証しない。

公式: [Vision pricing](https://cloud.google.com/vision/pricing)、[Groq Qwen](https://console.groq.com/docs/model/qwen/qwen3.8-27b)、[Groq rate limits](https://console.groq.com/docs/rate-limits)。音声は既存Turbo $0.04/audio hour・最低10秒・token対象外を維持。USDが一次情報、FX値の追加・変更なし。

## 実Dev E2E（新規fixtureのみ）

`forta-aogaku-dev`で画像6/PDF6、create→signed upload→complete→実worker/provider→ready→list/evidence/retrieve→named DB、defaultに同source不存在、duplicate receiptを検証。各routeのmethod/page locator、Qwen usage/費用、nativeでOCR/AI units=0を確認。

| fixture | native/OCR/AI | total tokens実測 | 推定USD | 最終worker処理時間 |
|---|---:|---:|---:|---:|
| plain.png | 0/1/0 | 0 | $0.001500 | 3.117 s |
| handwritten.png | 0/0/1 | 2163 | $0.003851 | 3.797 s |
| arrows.png | 0/0/1 | 2131 | $0.003723 | 4.511 s |
| diagram.png | 0/0/1 | 2149 | $0.003795 | 3.644 s |
| chart.png | 0/0/1 | 2063 | $0.003451 | 2.559 s |
| screenshot.png | 0/1/0 | 0 | $0.001500 | 2.343 s |
| text.pdf | 1/0/0 | 0 | $0.000000 | 1.999 s |
| scanned.pdf | 0/1/0 | 0 | $0.001500 | 2.557 s |
| diagram.pdf | 0/0/1 | 2168 | $0.002371 | 3.726 s |
| mixed.pdf | 0/0/1 | 2135 | $0.002239 | 3.711 s |
| table.pdf | 0/0/1 | 2132 | $0.002227 | 3.303 s |
| mixed-30.pdf | 26/1/3 | 6504 | $0.008614 | 16.836 s |

mixed-30.pdf: p4,p15,p27がAI、p6がOCR、他26ページnative。Qwen input5907/output597/total6504、AI $0.007114 + OCR $0.001500 = $0.008614。全30ページAIに送る場合との比較で呼出し数は30→3（90%削減）。全AI30ページの請求額／時間は実測しておらず、同一金額・速度改善率を断定しない。単一text PDF 1.999s・外部API$0、scan PDF 2.557s・$0.001500、図PDF 3.726s・$0.002371が今回の比較値。

processingMsは最終worker attemptの処理時間であり、queue待機や以前のfailed attemptを含まない。Groq429が発生した矢印fixtureは既存Tasks retryでAIとして復旧し、OCR evidenceへdowngradeしなかった。ページmsも成功したpage処理の値で、PDF analyze/render全工程や全retry latencyの比較には使わない。

Dev deploymentはcohort10のsource更新後、CLI queue guardが「未指定null」を誤検出して停止した。現稼働10件のmodule/依存manifestをSourceCodeGetで照合し、再deployせず全件ACTIVE、env/SA/trigger/IAM/Rules/indexes/Secret/bucketを確認して復旧。GCF生成FUNCTION_SIGNATURE_TYPE=http（以前未設定のaiListSourcesだけ）を照合。DBの移動retention watermark/etagと既存Dev Schedulerの実行telemetryはconfig driftと区別し、業務env・allowlist・sharing・SA等は厳密比較した。queue PATCH/purge/deleteを回避するDev preloadも追加した。

Dev queueは開始RUNNING→一時PAUSED/drained→検証後RUNNING。既存Dev Schedulerは開始時からENABLEDで、そのconfig/stateを変更していない。本番Scheduler PAUSED状態へはアクセス・変更していない。Rules/IAM/Secret/allowlist変更なし。Dev client direct accessは匿名・本人のnamed Firestore GET/PATCH、Storage GETの6 checksで403。

## science under attack.pdf（提供コピー・Dev実通信）

コピーはignored buildのみ、原本/GoodNotes package未変更。30ページ実PDFをPDF.jsで解析し、p4 Scientific Method循環図・p15画像併置・p27画像主体を目視確認。p4はOCR文字精度にかかわらずAI、p6等の文字ページはnative。

2026-10-09に指定PDFのDev Vision/Groq送信を利用者が明示承認。--reference-only と --approve-reference-provider-send の両方を要求し、syntheticの承認だけでは送信しない。固定された提供コピーだけを対象とし、SHA256をprivate registryへ記録。過去の12件のregistry/evidenceは再利用・上書きせず、別のignored build/visual-router-reference-dev/ に新規保存する。再deploy、Rules/IAM/Secret/allowlist変更は不要だった。

以下の表は実provider結果ではなくローカル第1段階の判定。23native、明確AI4、probe後決定3。

| page | ローカルroute段階 | score | 理由 |
|---:|---|---:|---|
| 1 | native_text | 0.050 | embedded_text_available, low_visual_complexity |
| 2 | native_text | 0.000 | embedded_text_available, low_visual_complexity |
| 3 | native_text | 0.003 | embedded_text_available, low_visual_complexity |
| 4 | multimodal_ai | 0.550 | embedded_visual_content, high_visual_complexity |
| 5 | native_text | 0.001 | embedded_text_available, low_visual_complexity |
| 6 | native_text | 0.032 | embedded_text_available, low_visual_complexity |
| 7 | native_text | 0.026 | embedded_text_available, low_visual_complexity |
| 8 | native_text | 0.031 | embedded_text_available, low_visual_complexity |
| 9 | native_text | 0.065 | embedded_text_available, low_visual_complexity |
| 10 | native_text | 0.039 | embedded_text_available, low_visual_complexity |
| 11 | 要OCR probe（不足ならAI） | 0.025 | probe_unavailable |
| 12 | native_text | 0.046 | embedded_text_available, low_visual_complexity |
| 13 | native_text | 0.026 | embedded_text_available, low_visual_complexity |
| 14 | native_text | 0.059 | embedded_text_available, low_visual_complexity |
| 15 | multimodal_ai | 0.779 | connectors_or_grid, semantic_vector_drawing, embedded_visual_content, non_text_visual_content, irregular_reading_order, high_visual_complexity |
| 16 | native_text | 0.114 | irregular_reading_order, embedded_text_available, low_visual_complexity |
| 17 | 要OCR probe（不足ならAI） | 0.025 | probe_unavailable |
| 18 | native_text | 0.004 | embedded_text_available, low_visual_complexity |
| 19 | native_text | 0.049 | embedded_text_available, low_visual_complexity |
| 20 | native_text | 0.047 | embedded_text_available, low_visual_complexity |
| 21 | native_text | 0.010 | embedded_text_available, low_visual_complexity |
| 22 | 要OCR probe（不足ならAI） | 0.025 | probe_unavailable |
| 23 | native_text | 0.005 | embedded_text_available, low_visual_complexity |
| 24 | native_text | 0.034 | embedded_text_available, low_visual_complexity |
| 25 | multimodal_ai | 0.600 | connectors_or_grid, embedded_visual_content, non_text_visual_content, high_visual_complexity |
| 26 | native_text | 0.004 | embedded_text_available, low_visual_complexity |
| 27 | multimodal_ai | 0.550 | embedded_visual_content, high_visual_complexity |
| 28 | native_text | 0.048 | embedded_text_available, low_visual_complexity |
| 29 | native_text | 0.002 | embedded_text_available, low_visual_complexity |
| 30 | native_text | 0.031 | embedded_text_available, low_visual_complexity |

### 指定PDFの実provider結果

30/30ページがready、Evidence30件・page locator30種類、list/evidence/retrieve context、duplicate受付、named保存/default同source不存在を確認。native23、Vision OCR最終本文0、Qwen7（p4/11/15/17/22/25/27）。Vision probeはp11/17/22の3 unitsで、低いOCR品質からQwenへ進み、その費用も集計した。

Qwen input6615 / output1077 / total7692 tokens。AI $0.009600 + OCR probe $0.004500 = estimated $0.014100。最終worker attempt 8.636秒。既存Tasks4attemptがGroq429でretryable failureとなり、同sourceを1回だけ明示retryしてcheckpointから完了（attempt5）。queue待機・失敗attempt・再送以前の呼出し時間や課金を含む総額/総時間ではない。各完成ページのusage/costを再利用して集計し、nativeページで外部provider呼出しなし。

| AI page | input | output | page推定USD（probe含む） |
|---:|---:|---:|---:|
| 4 | 945 | 226 | 0.001660 |
| 11 | 945 | 18 | 0.002328 |
| 15 | 945 | 220 | 0.001636 |
| 17 | 945 | 16 | 0.002320 |
| 22 | 945 | 18 | 0.002328 |
| 25 | 945 | 326 | 0.002060 |
| 27 | 945 | 253 | 0.001768 |

native pages: 1/2/3/5/6/7/8/9/10/12/13/14/16/18/19/20/21/23/24/26/28/29/30。

実返却結果をignored XCTest resourceへコピーし、30ページのroute・locator・p4/p6/p27・page header・costカードを検証。本人/匿名のFirestore GET/PATCH・Storage GETは6/6で403。provider返却本文、PDF本体、授業情報snapshot、UID/tokenはcommitしない。

E2E PASSは保存・自動route・provider実通信・根拠検索の技術契約を指し、意味精度の保証ではない。p4を元画像と目視比較したところ、Qwenは図に描かれていないResult→Observationの戻り矢印も補完していた。主要step/描画済み方向は取得できたが、この過剰補完は認識品質の残課題として記録し、本番導入判断では別途評価する。本文を人手で書き換えてPASSにする操作はしない。

## 回帰結果

- TypeScript build / recovered build PASS。
- domain / recognition / Router / Router safety 45/45 PASS（提供PDFのlocal 3ページ検証含む）。
- named/default Emulator worker、quota、再送、削除、遅延処理、旧AI/旧ASR/友人通知、Rules回帰50/50 PASS。
- offline iOS Debug build / AIDetectionResult + RecognitionLab XCTest: 26 PASS、1 opt-in Dev-network test SKIP、0 FAIL。ignored実Dev12結果をdecodeし、カード表示・内訳・cost・page locatorを確認。
- Phase4/5a / environment / recognition migration / Router guard44/44 PASS。
- Python環境分離・named DB・production安全・Lab isolation32/32 PASS。
- Dev synthetic実通信12/12 PASS、指定PDF実通信1/1 PASS、各直接アクセスdeny6/6 PASS。

古いproduction reviewのbyte一致テストは初回、新Routerとのhash差で安全に拒否した。旧artifactは保存したまま、新Router専用offline reviewを別build directoryへ生成し、テストは各versionに対応するartifactと照合するように更新した。旧review.verifyContractはschema4/image-ai-v2限定のままであり、新Routerの本番承認として利用できない。

## 本番対象Functions / migration / rollback（未承認・未実行）

対象cohort10:

1. aiProcessSource: version分岐・PDF renderer・Router・checkpoint・認識metadata。
2. aiGetSource: source認識情報の一貫したread。
3. aiGetEvidence: active-run＋routing/page情報。
4. aiRetrieveContext: mixed-method/page番号付きchunksの検索。
5. aiRetrySource: 保存済みpipelineVersionを保って再送。
6. aiUpdateSource: 認識metadataを維持。
7. aiDeleteSource: 同じruns/checkpoint/Storage subtreeを既存cleanup。
8. aiCompleteSource: auto-version受付をそのままworkerへ渡す。
9. aiCreateSource: 新sourceだけschema5/image-auto/pdf-auto。
10. aiListSources: 最後に新image/PDF capabilitiesを公開。

get/evidence/retrieve/update等のwire形式は従来のrecognitionにoptional routingを追加する。既存key/型や旧source receiptは維持。create/worker/listが必須変更だが、共有moduleを使うread/retry/cleanup契約を同一artifactの10件cohortとして揃える。aiLinkSourceOffering、reconcile、Storage trigger、旧AI、account deletion、友人通知は対象外（新しいsubtreeを増やしていない）。Functions endpointloaderの他exportをまとめてdeployしない。

本番反映は新しい承認が必要。fresh project ID/number/bucket/bundle/named DB＋全Functions source/env/IAM、Rules/indexes、Secret metadata、queue/Schedulerを照合。live pilot allowlist全文一致を保ち、sharing OFF、Scheduler PAUSED、App Check enforcement unchanged。queue PAUSEして既存workerをdrain。fresh専用artifactでworker→read/evidence/search→retry/update/delete→complete→create→listの順、1件ごとにinstalled full manifest/protected stateを照合。全cohort PASS後だけ開始RUNNINGへ復旧し、pilotで新規画像・mixed PDF・既存OCR閲覧・音声/メモ回帰・非pilot/direct access denyをE2E。

旧production approval/ZIP/receiptを新schemaに流用しない。`production_visual_router_review.cjs prepare` はoffline候補作成だけで、本番deploy runnerを追加/実行していない。旧deploy runnerは旧artifactを指すため新Router実行には使用不可。

部分更新失敗時はqueue PAUSEDのまま停止し、force/all Functions deploy/IAM workaroundを行わない。rollbackはfreshに回収したbefore source ZIP/全metadataへ10件を戻す承認が必要。schema5のpending sourceがある場合、旧workerへ無条件に流さず隔離/再送判断が必要。旧workerはauto-versionをQwen v2/旧PDFとして扱えるため、pending auto資料の正常処理を保証しない。新Router対応workerを保ったままcreate/listだけ旧受付へ戻す段階rollback案も、個別の承認・source/env照合を要する。既存ready資料の一括再処理・データ削除はしない。

## 変更ファイル / Git / privacy

- functions/src/ai/visualRouter.ts（config/score/metadata/capability/contract）
- functions/src/ai/visualExtraction.ts（PDF analyzer/render、Vision probe、Qwen route/checkpoint）
- functions/src/ai/index.ts / pricing.ts（新source/worker、集計料金config）
- functions/package.json / package-lock.json（canvas明示依存のみ）
- functions/test/visual-router.test.cjs / emulator.test.cjs（unit/実renderer/worker/security回帰）
- Aogaku/AIInput/AIDetectionResult.swift / AIDetectionResultView.swift / SourceIngestionService.swift（metadata decode・内訳・診断・page本文）
- AogakuTests/AIDetectionResultTests.swift（新旧表示/契約/実Dev結果）
- scripts/visual_router_fixtures.cjs / visual_router_dev.cjs / visual_router_dev_preload.cjs / deploy_detection_dev.py（fresh fixture、Dev cohort、queue保持、E2E/audit/cleanup）
- scripts/production_visual_router_review.cjs / test_visual_router_safety.cjs / test_production_recognition_review.cjs（offline新候補・旧承認再利用拒否）
- scripts/test_recognition_lab_safety.py（Labの独立packageとproduction config保護を維持し、意図した本体renderer依存変更を区別）
- docs/ai-input/visual-router.md（本書）

private auth registry/UID/token、.env、plist、source ZIP、実行evidence、実PDF/PNG、Dev result fixtureはignored build/及びAogakuTests/DevFixtures/のみ。既存tracked生成物functions/lib/index.js・node_modules lockのbuild差分はソースと分離し、終了時にこの作業の生成差分だけ戻す。元からのAogaku.xcscheme差分とscripts/__pycache__は保持。main/Phase5a branch/Aogaku-clean未変更。既存feature branchにsource/test/docsだけを保存し、private/generatedファイルは含めない。

最終Dev監査: `VISUAL_ROUTER_DEV_E2E_PASS_CLEANED`。今回の使い捨てAuth・12 sourceの原本/派生物・runs・usageをcleanup済み。再生成防止用owner/source tombstoneは保持。registryのID/refresh tokenは除去済み。既存Dev users/dataは未変更。

privacy scan: 今回変更/追加のsource22ファイル、private UID5値との照合、server-key/private-key/JWT/signed-URL検査で0件。private config、.env、Dev result/registry、参考PDF、実行evidenceはuntracked/ignored。今回stage前scan21ファイル/private UID10値照合で0件。commit前にもstaged全ファイルを再scanする。

## 指定PDFのDev再確認コマンド

以下は利用者がそのPDFの外部provider送信を明示承認した場合だけ実行する。privateな前回synthetic final/contextが必要。fresh registryが存在する場合は新規E2Eを再実行せず、停止して結果を確認する。

```sh
node scripts/visual_router_dev.cjs reference-preflight --reference-only
node scripts/visual_router_dev.cjs e2e --reference-only --approve-reference-provider-send
node scripts/visual_router_dev.cjs reference-access --reference-only
node scripts/visual_router_dev.cjs cleanup --reference-only
node scripts/visual_router_dev.cjs final --reference-only
```

Groq429でfailedの同reference sourceを、状態/ownership/hash確認の上で明示的に1回retryする場合のみ、E2Eに `--resume-failed-reference` を指定する。新Auth/source/uploadは作らず、既存APIのretry上限を維持する。transport mutation自動retryはしない。

指定PDFの最終Dev監査も VISUAL_ROUTER_DEV_E2E_PASS_CLEANED。使い捨てAuth1件、PDF source1件の原本/派生物/runs/usageはcleanup済み、owner/source tombstoneのみ保持。registryのID/refresh tokenは除去済み。稼働Functionsのmetadata/source、Rules/indexes/IAM/Secret/bucket/lifecycleはfresh baselineから不変。queue RUNNING、既存Dev Scheduler ENABLEDのconfig/stateは変更なし。このターンのFunctions deployは0、本番アクセス・mutationも0。

# 授業AIの検出結果と認識方式（2026-10-08）

実装ブランチ: `codex/ai-input-detection-results`。基点はPhase 5aの `927a3d65c43ba863f94fc995aaef91e5abc0e02d`。Recognition Labブランチは参照のみ。通常Aogaku Schemeの既存ローカル変更は今回の対象外。

## UI・本文の契約

授業AI会話の添付／メッセージと入力欄の間に「検出結果」を配置。資料選択メニューで同じ授業回の送信資料を切り替え、初期値は最後の送信資料。解析待ち、最終本文、model／時間、Token一文、Cost一文、料金基準日を表示。失敗時は既存retryへ接続。RAW OCR、provider JSON、秘密値は表示しない。閲覧中のアカウント変更／削除では表示・会話・添付を消去。

本文は `aiGetEvidence` のactive runを全ページ取得し、chunk `unitIndex` とUTF-16の `startChar/endChar` でoverlapを除いて復元する。別ページ／別音声区間は別unitなので同じ文でも消さない。取得前後の `aiGetSource.activeVersion` と各ページのrevisionを確認する。旧APIのページにrevisionがない場合も取得前後のsource revisionで検証。旧Vision資料は既存chunksを読むだけで再処理しない。旧chunkには最大200文字の既知overlapのみ照合する。

## 画像・音声・料金

画像providerは交換可能な `ImageRecognitionProvider`。採用候補は **Groq `qwen/qwen3.8-27b`**。元画像をdata URIで直接渡し、手書き・矢印・図表・位置対応を根拠のある自然文へ変換する。読めない部分は不確実とし、矢印だけで因果を断定しない。JSONの `finalText` だけを検証してchunksへ格納。モデル一覧の正式IDを照合し、利用不可／不完全JSON／429／5xxは再試行可能なエラー。画像のGoogle Vision／Apple OCRへのfallbackはない。既存10MB制限を維持。

公式モデルページではこのQwenはPreview扱い。正式ID・画像仕様・料金を確認済みでもproduction安定性の保証とは別なので、一般公開前にPreviewモデル採用を明示判断する。モデル変更は `pricing.ts` とprovider adapterで行い、料金不明の返却modelには価格を推定しない。

`usage.prompt_tokens/completion_tokens/total_tokens` のAPI実測のみを保存。画像tokenizationを独自推定しない。欠損はnull／取得不可。画像costは `input/1e6*0.80 + output/1e6*4.00` USD。

音声は **Groq `whisper-large-v3-turbo` のみ**。既存15分分割・2秒overlapと時刻を維持。Apple Speech／Whisper accurateへのfallbackはない。成功した各API requestで返ったduration（欠損時は送った分割音声のffprobe実測）に最低10秒を適用し、その合計を `billedAudioSeconds` とする。costは `billedAudioSeconds/3600*0.04` USD。部分成功は成功した区間のみの推定額で、失敗requestの請求額や全retryの請求額を保証しない。API本文を取得できなかった通信断の請求量は不明。

料金は `functions/src/ai/pricing.ts` に集約。USD、`pricingAsOf=2026-10-08`、`pricingVersion=groq-2026-10-08-v1` をmetadataに保存。JPYは表示用Remote Config `ai_recognition_usd_jpy` が正の有限値の場合のみ「約」で表示。現在値をこの作業で設定しない。推定額であり実請求額ではない。PDF本文抽出／必要ページのVision OCRとメモ方式は変更しない。PDFのVision料金を画像AI料金に混ぜない。

一次資料:
- [Groq Qwen model](https://console.groq.com/docs/model/qwen/qwen3.8-27b)
- [Groq Vision](https://console.groq.com/docs/vision)
- [Groq Speech-to-text（最低10秒／timestamps）](https://console.groq.com/docs/speech-to-text)
- [Groq API response usage](https://console.groq.com/docs/api-reference)

## 保存境界・互換性

AIデータは明示的 `aogaku-ai`。`(default)` はclasses catalog／既存ユーザー／legacy deletion fence。DBを跨ぐtransactionを使わない。Rules・indexesは変更不要。原本 `ai-inputs/aogaku-ai/{uid}/{sourceId}/original`、派生物 `ai-derived/aogaku-ai/...` は現行prefixのまま。音声ready後の原本削除と削除helperも維持。

新sourceはschemaVersion 4。画像pipeline `image-ai-v2`、音声 `audio-groq-v2`。`recognition` mapにprovider/model/method/pipelineVersion/processingMs、画像tokens、音声duration/billed duration、cost、pricing日/versionを保存。新chunkの `unitIndex` とUTF-16 offsetsは検索本文と共通。旧source・chunkはmetadataなしでも読む。

新認識runのStorage manifestには本文を再複製せず、coverageとrecognitionだけを保存。chunksが最終本文。再開用checkpointには必要な成功区間のみ保持し、既存資料削除／アカウント削除でcleanupする。PDF／メモの既存保存契約は変更しない。

## 自動認証・一般利用の準備

`AIInputSession` は既存Auth accountを保持し、未認証の場合だけ自動 `signInAnonymously()`。同時呼び出しをまとめ、ログイン画面・UID登録画面を出さない。匿名AI sessionで設定タブへ移動せず、既存時間割同期やFCM登録を開始しない。本人が通常ログインへ切り替える場合、匿名資料は勝手に別UIDへ移管しない。端末からの匿名account喪失時の復元／account linkingは今回追加していない。

productionは既定で **pilot** のまま。`AI_INPUT_ADMISSION_MODE` 未定義はpilot。pilotは現在のprivate allowlistを維持し、ハードコードしない。

将来 **public** を明示する場合、`AI_INPUT_REQUIRE_APP_CHECK=true` が必須。Authなし・App Checkなし・未知modeは処理前に拒否する。Callable SDKのenforceAppCheckとhandler双方で検査する。workerはprivate Tasksのまま、Auth UIDのadmissionとowner／tombstoneを検査する。公開切替の際はworkerにもpublic modeとrequire flagを揃える。共有はproductionでhard OFFを維持する。

既存quota: 100資料／日、500MiB／日、音声10800秒／週。追加: 全Callable合計120request／UID／分、Groq100request／UID／日（音声は分割request毎、失敗attemptも消費）。named `aiUsage/{uid}/periods` のtransactionで検査し、削除stateを再確認する。既存account cleanupで新counterも削除される。providerの無制限なretryを避け、既存worker試行上限・maxInstancesを維持。App CheckはUID再発行によるquota回避を完全には防がない。一般公開前に匿名Auth作成制限、provider account限度、予算アラートと監視を確認する。課金プランは追加しない。

## productionへ反映する前の順序と設定

本作業はproductionへアクセス／deployしない。現行pilot・queue・Scheduler・Rules・indexes・Secretを変更しない。既存Phase 4/5a approvalは新sourceに流用不可。既存production wrapperもpublicへの切替は承認できないので、public rolloutは別のfresh artifact／専用承認が必要。

1. Firebase ConsoleでproductionのAnonymous AuthとApp Check App Attest登録（Team ID／Bundle ID）を準備。全Firestore／Storage／旧Functionsの一括enforcementはしない。
2. Dev／内部ビルドでApp Check metrics、実機App AttestとDeviceCheck fallbackを検証。Simulatorは `AOGAKU_APP_CHECK_DEBUG=1` とConsole登録済みdebug tokenをprivate管理する。debug providerはReleaseで無効。
3. production metadata／稼働sourceをfreshに取得し、pilotのまま下記10 Functionsの最小source更新を別承認。まず新／旧資料の内部E2E。Secretの変更／rotation、既存Rules緩和は不要。
4. 新appのApp Check metricsが揃ってから、新AI Callableだけのenforcementを別承認。`public`＋require flagを9 Callableとworkerへ揃える。現行pilotに未対応clientが残る間は一括切替しない。worker・Eventarc・Schedulerのpublic invoker追加不要。
5. quota／監視／Previewモデル採用と実機録音を確認し、一般公開やApp Store公開は別承認。sharing OFF／Scheduler状態はこの変更と切り離す。

最小production Functions更新:
`aiCreateSource`, `aiCompleteSource`, `aiGetSource`, `aiListSources`, `aiGetEvidence`, `aiRetrySource`, `aiUpdateSource`, `aiDeleteSource`, `aiRetrieveContext`, `aiProcessSource`。
Dev専用 `aiLinkSourceOffering` は共通Callable変更のためDevでのみ更新。新受付方式の切替前に待機中の旧image/audio jobも確認する。ready資料は再処理しないが、未完了／明示retryの資料は新方式で処理される。`aiReconcileInputs`／`aiRejectLateUpload`／削除3件／旧AI3件／通知は今回のproduction更新対象にしない。共通moduleが含まれていても全Functions deployをしない。

Rollback: public切替前のprivate pilot config／fresh source artifactを保存し、admissionをpilotへ戻す（UIDをsourceに埋め込まない）。必要なら新規受付をclosed、queueをPAUSEDへ戻す操作を別承認。新方式でreadyになった資料はchunksを保持し、そのまま読む。旧OCRへ自動fallback／既存資料一括再解析／DBやRulesの巻戻しは行わない。iOS表示のみ不具合なら直前app buildへ戻す。provider障害時はsource failed／retryableで明示する。

参考: [Firebase Anonymous Auth](https://firebase.google.com/docs/auth/ios/anonymous-auth)、[App Attest導入とmetrics→enforcement](https://firebase.google.com/docs/app-check/ios/app-attest-provider)。

## 再現するテスト

- `npm --prefix functions run build`
- `node --test functions/test/domain.test.cjs functions/test/recognition.test.cjs`
- `node --test scripts/test_production_phase5a.cjs scripts/test_production_phase5a_revision.cjs scripts/test_production_read_retry.cjs`
- `firebase emulators:exec --project demo-aogaku-input --config firebase.detection-test.json --only firestore,storage 'node scripts/run_detection_emulator.cjs'`
- Xcode `Aogaku-AI-Input-Tests` Debug、Simulator。`AIDetectionResultTests`／`AIInputDevIntegrationTests`。Devネットワーク2件は明示opt-in。
- 承認済みDevのみ: `deploy_detection_dev.py` はfresh `build/detection-dev-before.json` とprivate Dev parametersを必要とし、明示11 Functions限定。`detection_dev_e2e.cjs` はsynthetic assetsとfresh匿名Auth、既存と衝突しない5桁class fixtureだけを使用。private registryは `build/detection-dev-e2e/`（ignored）。失敗後の自動mutation replayはしない。

実機マイク／長時間録音・着信・強制終了・App Check attestationのproduction実通信は、今回のSimulator／Emulator検証とは別に必要。

## 今回の検証結果・変更ファイル

- TypeScript build: PASS。
- Domain／画像AI／音声料金／admission＋Phase 4／Phase 5a／read-only retry guard: 42/42 PASS。
- named/default DB・Rules・旧AI／旧文字起こし／友人通知・削除・新認識worker／quotaのEmulator: 49/49 PASS。外部通信はmockのみ。
- Firebase環境分離: 9/9 PASS。Dev cloud target/Secret payload拒否: 5/5 PASS。
- offline iOS Debug build／XCTest: 12件中9 PASS、Dev opt-in 3 SKIP、失敗0。
- signed SimulatorのDev実通信: 自動匿名Auth→端末保存→worker→aiGetEvidence→検出結果View→syntheticメモ削除 PASS（1/1）。最初のunsigned buildはKeychain entitlementで失敗し、ad-hoc署名で解消。
- Dev実通信: fresh匿名2アカウント、メモ／画像Qwen／PDF本文＋Vision OCR／音声Turbo、evidence／retrieve context、重複受付、他UID拒否、direct DB／Storage拒否、年度snapshot、named usage分離すべてPASS。旧LabのDev model availability／画像・音声実通信もPASS。
- Dev更新11 FunctionsはすべてACTIVE。対象外6 Functionsはmetadata/updateTimeまで一致。named DBの構成、Rules release、bucket/lifecycle、Secret versions、queue設定は不変。既存Dev SchedulerはENABLEDのまま（今回作成／resume／設定更新なし）。自然なscheduleTime/lastAttemptTimeとDB earliestVersionTime/etagの変化だけを区別した。
- 本番Firebaseへのアクセス／変更0。commit／push／merge／公開0。秘密／既知private UID scan PASS、stage 0。

旧本番artifactを直接読む追加検査はprivate `build/production-phase3b/candidate` がこの作業コピーにないため一部実行不可。今回production sourceを取得し直さず、既存削除・quotaはEmulator実ソース回帰で確認した。Phase 4 closed artifactはローカル再生成してguard 6件をPASSした。新production移行時はfresh deployed artifactで再照合が必要。

Dev synthetic fixtureは新runの匿名2アカウント・5桁class1件・ready source4件のみ。`build/detection-dev-e2e/registry.json` に所有者／source IDs／Auth tokenをprivate管理し、既存Dev fixtureへ上書きしない。後片付けはregistryのproject／owner／testRunIdを照合し、対象sourceを `aiDeleteSource`、当該synthetic classと新規Authだけを削除する。既存Lab account／過去fixture／実ユーザーを削除しない。iOS追加testのメモはCallableから削除済み。証跡・fixtureはGitへ含めない。

変更ファイル（本作業28件）:

- `.gitignore`
- `Aogaku.xcodeproj/project.pbxproj`
- `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Input-Tests.xcscheme`
- `Aogaku/AIInput/AIAppCheck.swift`
- `Aogaku/AIInput/AIDetectionResult.swift`
- `Aogaku/AIInput/AIDetectionResultView.swift`
- `Aogaku/AIInput/AIInputSession.swift`
- `Aogaku/AIInput/AppBackend.swift`
- `Aogaku/AIInput/SourceIngestionService.swift`
- `Aogaku/AIInput/SourceModels.swift`
- `Aogaku/CourseDetailViewController.swift`
- `Aogaku/PushManager.swift`
- `Aogaku/SettingsHostViewController.swift`
- `Aogaku/timetable.swift`
- `AogakuTests/AIDetectionResultTests.swift`
- `docs/ai-input/DETECTION_RESULTS.md`
- `firebase.detection-test.json`
- `functions/src/ai/admission.ts`
- `functions/src/ai/domain.ts`
- `functions/src/ai/extractors.ts`
- `functions/src/ai/index.ts`
- `functions/src/ai/pricing.ts`
- `functions/src/ai/recognition.ts`
- `functions/test/emulator.test.cjs`
- `functions/test/recognition.test.cjs`
- `scripts/deploy_detection_dev.py`
- `scripts/detection_dev_e2e.cjs`
- `scripts/run_detection_emulator.cjs`

以前からある `Aogaku.xcscheme` のDebug→Release変更と `scripts/__pycache__/firebase_dev.cpython-311.pyc` は本作業の対象外としてそのまま保持。tracked生成物 `functions/lib/index.js` は元のHEAD内容へ戻し、ソースと分離した。private Dev env、Dev plist、test context、token registry、build証跡はignored／未tracked。

新規画像の本番旧OCR誤送信を防ぐ追加修正とDev再検証は [IMAGE_AI_ROUTE_FIX.md](IMAGE_AI_ROUTE_FIX.md) を参照。通常Aogaku Schemeは本番であり、Qwen workerは今回Devだけに反映。

現在のpilotを維持する本番移行の承認対象・contract・rollbackは [PRODUCTION_RECOGNITION_REVIEW.md](PRODUCTION_RECOGNITION_REVIEW.md) を参照。一般公開/App Check新規強制ON/Anonymous Auth設定変更はこの移行に含めない。

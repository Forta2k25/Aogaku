# 本番画像Qwen / 音声Turbo移行前レビュー

状態: **REVIEW_READY_AWAITING_APPROVAL**（2026-10-08）。今回は本番read/deploy/mutationなし。通常 `Aogaku` Scheme / Release / `com.forta2k25.Aogaku` / production設定は保持。本番の現在値を検証済みとは扱わず、承認後のfresh preflightを必須とする。

## 承認候補と対象

Project `forta-aogaku`、Number `505828754933`、bucket `forta-aogaku.firebasestorage.app`、named DB `aogaku-ai`、Functions Tokyo、既存runtime SAを維持。対象は以下10件を同一source artifactで更新する。全Functions deploy、CREATE、DELETEは対象外。

| Function | 変更内容 / contract依存 |
|---|---|
| aiCreateSource | 入力形式・clientRequestId fingerprint・年度snapshot維持。新source schemaVersion=4、image-ai-v2 / audio-groq-v2。receiptにpipelineVersion/recognition/processingMsを追加。共通pilot gateとrequest quota。 |
| aiCompleteSource | PUT完了・generation/size/mime検査とenqueueは維持。上記source receiptを返すため同時更新。 |
| aiGetSource | processing/ready/failedの状態とactual recognition metadataを返す。旧sourceはinput-v1 / recognition=null。 |
| aiListSources | 各sourceに同じmetadata。inputCapabilities.imageでGroq Qwen、AI-only、fallback=falseを宣言。iOS新規画像の送信前gateのため最後に公開。 |
| aiGetEvidence | actual active-run chunksから最終本文。activeVersion/recognition/pipelineVersion/processingMsを追加。unitIndexとUTF-16位置情報でページ間・chunk重複を復元。 |
| aiRetrySource | 手動再送・既存retry上限/有効期限維持。新checkpoint / receipt / quota / pilot契約に揃える。ready資料はenqueueしない。 |
| aiUpdateSource | title変更と本人権限維持。production共有hard OFF。新receipt / 共通gateに揃える。 |
| aiDeleteSource | purge/Tasks取消/Storage/named DB cleanupは維持。共通gate / request quotaを揃える。削除3 Functionsは更新しない。 |
| aiRetrieveContext | 検索方式・目的・文字数・所有者/共有撤回検査は維持。v2 chunksのunit/locator情報を返す。共通gate / quotaを揃える。 |
| aiProcessSource | imageをGroq Qwen AI-only、audioをTurbo onlyへ切替。actual usage/cost保存、checkpoint検証、provider quota。PDF本文/Vision page OCRとnote維持。 |

対象外: aiReconcileInputs、aiRejectLateUpload、Dev専用aiLinkSourceOffering、旧AI3、削除3、友人/通知Functions。SDK内部で他handlerの定義をimportしても、candidate entryのexport/discoveryは10件のみ。Firestore/Storage Rules、indexes、lifecycle、Secrets、API、IAM、Auth provider設定、Remote Configの変更なし。

## Artifactとguard

`node scripts/production_recognition_review.cjs prepare` はOFFLINEのprepareのみ。deploy runnerは持たず、cloud credentials/private UID configを読まない。既存Phase4/5a evidenceも上書きしない。候補は `build/production-recognition-review/package`（Git除外）。Node22/9 callable + 1 task handler、named DB、target/bundleを確認。source manifest SHA:

`2061dbc03d0a6470879d185ee5ed85cd220bca5040d976a71717db1228ff1d56`

review.jsonは `productionDeploymentAuthorized=false` / `livePreflightCompleted=false`。これは実行承認receiptではない。allowlistの古い単一UID・古いsource SHAを固定しているPhase5a wrapper、全12 exportsを前提にしたfirebase_production.pyのdeployを流用しない。新候補のsource SHAとfresh deployed manifestを結び付けた承認記録が必要。

pure guardはfuture source-only `PATCH ?updateMask=buildConfig.source` だけを検証。10件の実live envはそのまま保持。env/IAM/Secret/RulesのPATCH、他Function、CREATE/DELETE、未承認、古いbaseline、未drain、default DB、general admission、wildcard UIDを拒否。Gen2 stagingは既存修正済みheader契約を使用し、fresh発行・upload成功・Project Number/region一致後のみPATCH可能。書込みの自動retry禁止、確認readだけ既存最大5回retry。

## 画像・音声と保存契約

画像正式値: provider=`groq`、model=`qwen/qwen3.8-27b`、method=`multimodal_ai`、pipelineVersion=`image-ai-v2`。元画像data URI → Groq multimodal → JSON finalText検証 → chunks保存。Vision/Apple OCRへのfallbackなし。モデル未提供、429/5xx、model不一致、JSON不完全、OCR checkpoint混入はretryable failure。サイズ/MIME不正や設定欠損・quotaは従来同様の入力/設定エラーと区別する。

音声: provider=`groq`、model=`whisper-large-v3-turbo`、method=`groq_asr`、pipeline=`audio-groq-v2`。既存15分分割/2秒overlapを維持、accurate model/Appleへのfallbackなし。

- `aogaku-ai/aiSources/{sourceId}.recognition`: provider/model/method/pipelineVersion/processingMs、画像inputTokens/outputTokens/totalTokens、音声audioDurationSeconds/billedAudioSeconds、estimatedCostUSD、pricingAsOf/pricingVersion。
- 画像tokensはGroq usageのprompt/completion/totalをそのまま取得。usage欠損はnull、推測しない。入力$0.80/M、出力$4.00/Mの2026-10-08料金snapshotから計算。
- 音声は各provider requestのminimum 10秒を含むbilled duration合計 / 3600 * $0.04。tokensはnull。UI「音声認識はtoken課金ではないため対象外」。
- sourceトップprocessingMsはworker全体、recognition.processingMsはprovider画像処理/音声抽出全体。UIはrecognitionの値を優先。
- 本文は `aiSources/{sourceId}/runs/{activeRun}/chunks/{chunkId}` を唯一の最終Evidenceとして使用。derived run manifestは新画像/音声ではmetadataのみ。再開用checkpointは従来Storage prefix内に保持。
- raw=`ai-inputs/aogaku-ai/{uid}/{sourceId}/...`、derived=`ai-derived/aogaku-ai/{uid}/{sourceId}/...`。default DBは実classes参照・既存deletion fenceのみ。AI本文/chunks/usageはdefaultに保存しない。
- `courseOfferingId=YR:5桁classDocId`。syllabus YR優先、時間割年度が次、双方なしはunresolved。資料保存snapshotは不変。

## 旧資料との互換性

ready/partial-readyのOCR済みEvidenceは保存済みactiveRunから読む。定期・一括再処理なし、workerのterminal判定はreadyをskip。旧recognitionなしをQwenと偽表示しない。「Google Vision OCR（保存済み結果）」を表示しtoken/costは不明扱い。新画像がimage-ai-v2ならprovider/model/methodとchunksを検証してQwen表示する。完成済み旧audioもそのまま。

旧schemaの保存資料と新schema資料の併存は互換性のため必要。なくすのは「更新対象10 Functionsが違うsource/API契約を実行する状態」。Firestoreの既存資料をv4へ一括migrationしない。旧未完了/failed画像・音声の明示retryは新workerが新方式で処理し、旧checkpointをQwen/Turboとして再利用しない。その場合、作成時schemaVersionが旧でも処理後pipelineVersion/recognition/activeRunが新実測契約になる。

## 保持する安全設定・既存への影響

最新live `AI_INPUT_ALLOWED_UIDS` を全10 Functionsから取得し、一致・非空・wildcardなしを確認。全既存pilotを残す。private configがstaleでもcloud allowlistを古い1 UIDへ戻さない。raw envをbyte単位で保存/照合し、source-only PATCHでenvを書き換えない。報告は件数/digestのみ。今回live allowlistの値・件数は取得していない。

`AI_INPUT_ADMISSION_MODE` は未定義またはpilotだけ。publicへ変更しない。App Check enforcementは現状維持（新規強制ONなし）。正常Auth+pilot UIDだけ処理、認証済み一般UID/匿名は拒否。既存9 CallableのHTTP到達性とRun/Function IAMを保持、workerはprivate、sharing=false、Scheduler PAUSEDを維持。

Dev版に含まれる追加制限も承認対象として明示: 9 Callable合計120 request/UID/min、Groq 100 provider request/UID/day（音声分割・失敗attemptも消費、checkpoint cacheは消費なし）。既存100資料/day・500MiB/day・音声10800秒/weekは維持。新counterはnamed aiUsage/periods内で、既存アカウント削除で消える。課金やAPI回数、provider latency、失敗率は変化する。Qwenは公式Previewモデルでありfallbackしない。

通常時間割・syllabus・friends・課題、他Function、授業catalog、Rules/Storage権限、共有/一般公開ポリシーに変更を加えない。iOSは現在のAogaku Release本番接続を維持。追加Anonymous Auth有効化やApp Check Console変更はこのpilot移行には含めない。

## 承認後の正確な順序

1. **Fresh read-only preflight**: project/number/bucket/bundle、25 Functionsのmetadata/source/updateTime/Run+Function IAM、named/default DB/Rules/indexes、runtime SA、queue/Scheduler/Eventarc、Secret metadata/versions（payload不可）、lifecycleを取得。current allowlist・App Check・ingressと全protected stateを保存。diff/driftは停止。旧source ZIP/full manifestsをrollback用private保存、最新artifactと結び付ける。過去approval/upload URLは流用しない。
2. **Queue一時PAUSEとdrain**（この操作も次の明示承認範囲）: aiProcessSource queueの現設定を保存、PAUSE、inflight旧worker完了を確認。旧image/audio job件数・leasesをread-onlyで確認し、task purge/cancelや資料削除はしない。Scheduler PAUSEDは変更しない。pauseでは実行中taskを停止できないため、旧revisionのworkerが0になるまでsource更新しない。timeout/長いleaseは停止。
3. **10件のsource cohort更新**: aiProcessSource → aiGetSource → aiGetEvidence → aiRetrieveContext → aiRetrySource → aiUpdateSource → aiDeleteSource → aiCompleteSource → aiCreateSource → aiListSources。1件ずつfresh staging/upload/PATCH/operation/full installed source/runtime/SA/trigger/env/IAM/protected-state post-check。一般Functions deployなし。途中失敗はqueue PAUSEDで停止。publish lastにより新iOSは途中でQwen非対応のままuploadを拒否する。
4. **Queue PAUSEDのままcohort最終確認**: 全10 ACTIVE/同manifest/旧資料閲覧、9 Callableの匿名・非許可UID拒否/許可UID admission、sharing OFF、metadata/null互換、対象外15 Functions不変、Rules/indexes/IAM/Secret/lifecycle不変。gen2 build/updateTime/revision/source参照だけはinstalled全source一致後に許容。business envは変更不可。
5. **Queueを開始時状態へ復旧**（RUNNINGだった場合だけ、全post-check PASS後の別の明示承認操作）: 設定/rateは維持しresumeは1回だけ。開始時PAUSEDなら勝手にresumeしない。SchedulerはPAUSED。
6. **既存pilotのみproduction E2E**: 下記synthetic 4入力、所有権/DB境界/旧資料を確認。既存pilot以外のAuth fixture作成が必要なら別承認。新規UID allowlist追加なし。成功/失敗とprivate registryを保存し停止。Phase5bへ進まない。

GCPの10 Functions更新は原子的ではない。queue停止はprovider/worker実行を止めるがCallableのHTTP応答を停止するものではない。移行中はpilotへ新規AI操作を控えるメンテナンス時間を設け、reader変更はadditive互換を維持する。listのcapability公開は最後、全cohort検証後にqueueを再開する。これを「一瞬も旧/new HTTP応答が併存しないatomic deploy」とは呼ばない。その保証が必要な場合は受付を一時private化する追加IAM変更が必要であり、今回のsource-only計画には含めない。

## rollback

最優先は処理停止。partial successでqueueを再開しない。正常なsource以外へ--forceや自動mutation retryで進まない。全10の最新before artifacts/metadata/env/IAMを保持し、affected sourceだけを明示承認に基づき戻す。allowlist/Secrets/Rules/indexes/default DB/lifecycleを巻き戻さず、AI資料/chunks/usageを削除・再処理しない。

**旧Vision workerへ戻した状態でqueueをresumeしてはいけない**（new image-ai-v2をOCRへ処理するため）。旧worker復旧はqueue PAUSEDの診断状態だけ。通常利用の復旧はQwen/Turbo-compatible修正版がPASSしてから。新AI ingress/受付を止める必要があればresource-scoped Callable IAMの一時private化を別承認。通常アプリは継続、pilot AIは停止する。この追加IAMは今回のsource-only承認には含めない。成功済みv2 Evidenceを読む互換readerは可能な限り維持する。DBバックアップrestore・Rules rollback・資料一括migrationは不要。

## production E2E / 完了条件

既存pilot本人の内部Xcode Aogaku build、本番ログイン、本番実時間割の選択授業（5桁id / syllabus YR / semester）を利用。新規の架空画像・合成音声・メモ・PDFだけを投入。実授業資料/個人情報をproviderへ送らない。既存classesはread-only、fixture用classes追加なし。

- 画像2枚: 新clientRequestId/異なるbytes → receipt image-ai-v2 → signed upload → private Tasks worker → Qwen → ready → multimodal_ai chunks → Evidence/検索/カードの正式model/token/cost/processingMs。Vision/Apple呼び出しなし、料金式と実usage一致。
- 音声: 新synthetic m4a → Turbo requestのみ → timestamp chunks → duration/billed seconds/processingMs/cost → Evidence/検索。「token課金ではないため対象外」。長時間実録音/障害注入はPhase5bへ残す。
- PDF: 本文あり＋スキャンページ → pdf_textと必要ページVision OCR、page番号保持 → Evidence/検索。メモ: text保存 → ready → Evidence/検索。
- 旧OCR ready資料: activeRun/chunks/updatedAt不変、既存本文表示、Groqへの再送なし。旧資料のcostは推測しない。
- duplicate receipt、新画像送信中断後retry、named(default)分離、snapshot不変、direct Firestore/Storage拒否、他UID拒否。新synthetic非許可Auth UIDが必要なら作成/削除の追加承認前に停止。
- final audit: 全10 same-source/ACTIVE、allowlistとsharing/App Check/ingress不変、worker private、queue開始時状態、Scheduler PAUSED、対象外15 Functions/source/updateTime不変、Secret version/Rules/indexes/lifecycle不変。fixtureはprivate registryのownership確認後、今回のtestだけを別cleanup承認範囲で扱う。
- 削除競合、遅延worker/upload、Scheduler実行、provider障害注入、quota限界、sharing ON、一般解放は今回のproduction移行E2Eに混ぜずPhase5bへ残す。

## 検証証跡と今回追加ファイル

TypeScript build PASS。今回のdomain/recognition/Phase5a/revision/read retry/移行guard/候補artifactテスト **51/51 PASS**。新guardは13/13（複数synthetic pilotのadmission、named DB未定義/fixedだけPASS、source-only PATCH、全installed source、source bytes一致、誤project/未drain拒否、Env/IAM/Secret変更拒否）。candidateにはprivate env/plist/UID/token/credentials/fixtureを含めない。

backendのDev-tested runtime bytesは候補と一致。前ターンのEmulator49/49、Simulator11 PASS/1 SKIP、Dev新規Qwen画像2/2、メモ/PDF/Turbo実通信とEvidence/検索は検証済み。本番では今回再実行していない。実live source/allowlist/queue/Scheduler等の最新確認、production E2Eは承認後の必須gateとして残す。

追加: `scripts/production_recognition_review.cjs`（offline prepare + pure future-deploy guards）、`scripts/test_production_recognition_review.cjs`、本document。既存Phase4/5a wrappers・Firebase設定・通常Scheme・pipeline source・private configはこのターン変更しない。Git commit/push/mergeなし。本番承認待ちで停止。

参考: [Groq Qwen formal model / Preview / price](https://console.groq.com/docs/model/qwen/qwen3.8-27b)、[Groq speech billing](https://console.groq.com/docs/speech-to-text)。

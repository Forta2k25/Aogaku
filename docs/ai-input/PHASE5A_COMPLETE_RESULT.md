# PHASE5A_COMPLETE

完了: **2026-10-07 15:09 JST**。対象: `forta-aogaku` / `505828754933` / bucket `forta-aogaku.firebasestorage.app` / named DB `aogaku-ai`。Release Bundle IDも照合済み。
指定pilot UID **1件だけ**利用可能。UID全文・tokenはGit除外のprivate configに保持。
Phase 5b、GitHub push/merge、App Store公開、sharing ON、Scheduler resume、Aogaku-clean変更は実施していない。

## production mutations

- 残り9 Functionsのenv-only PATCHを各1回。成功済み`aiCreateSource`は**再PATCHしていない**。
- 9 Callableの実Run serviceにだけ`allUsers / roles/run.invoker`を追加。既存binding保持。project-wide IAM変更なし。
- `aiProcessSource` queueを1回resume。現在RUNNING。
- 登録済みの使い捨て非許可Auth account **1件だけ**を削除。pilot accountは対象外。
- synthetic資料5件を作成: 通常4入力＋中断/再送用写真1件。原本upload、Tasks、本文/chunks、派生物、named usageは通常pipelineで処理。

再開ターンのcontrol-plane mutations: **19件 = env 9 + Run IAM 9 + queue resume 1**、すべてCONFIRMED。
前回の`aiCreateSource` PATCHを含むPhase 5a全体では20件。Auth cleanupと通常data-plane処理は別集計。
mutation自動retryは0件。fresh resume以降、read-only transient retryも0件。

## UID設定 / ingress

以下10件の`AI_INPUT_ALLOWED_UIDS`はprivate configのpilot UID 1件と完全一致。

| Function | HTTP/IAM状態 |
| --- | --- |
| aiCreateSource | HTTP到達可能、Firebase Auth＋pilot UID必須 |
| aiCompleteSource | 同上 |
| aiGetSource | 同上 |
| aiListSources | 同上 |
| aiGetEvidence | 同上 |
| aiRetrySource | 同上 |
| aiUpdateSource | 同上 |
| aiDeleteSource | 同上 |
| aiRetrieveContext | 同上 |
| aiProcessSource | private、既存Tasks/runtime SA binding保持 |

`aiReconcileInputs` / `aiRejectLateUpload`にはUID設定を追加せず、allowedUIDs空・privateを維持。
全12件Node22 / Tokyo / AI runtime SA / named DB固定 / sharing OFF。default DB fallbackなし。
12 Run serviceのReady revision、runtime SA、実env、invoker IAM enforcementも照合済み。

## Auth / direct-access checks

9 Callable × 3条件、**27/27 PASS**。

| 条件 | 件数・結果 |
| --- | --- |
| anonymous | 9件UNAUTHENTICATED、拒否 |
| valid production Auth・非許可UID | 9件AI_INPUT_NOT_ENABLED、拒否 |
| valid production Auth・pilot UID | 9件admission通過、null入力はINVALID_REQUEST |

null入力はaccount/DB/Storage/provider処理前に停止し、非許可UIDにfixture副作用なし。
27件PASS後にqueueをresume。
pilot資料への非許可UIDの`aiGetSource` / `aiGetEvidence` / `aiRetrieveContext`も3/3拒否。
Firestore直接read / Storage直接readはanonymous・pilot・非許可UIDの**6/6件403**。
background 3件の両URLへのanonymous accessも**6/6件拒否**。

## 本番E2E

| 入力 | 本番処理と結果 |
| --- | --- |
| メモ | create→worker→ready→list→evidence→retrieve context PASS。文字位置付き根拠1件 |
| 写真 | signed PUT→raw size/MD5確認→Vision OCR→ready→根拠1件→検索 PASS |
| PDF | 本文`pdf_text`＋画像ページ`vision_ocr`→ready。ページ番号1/2の根拠2件→検索 PASS |
| 音声 | synthetic TTS 12.466秒→signed PUT→Tasks→Groq ASR→ready。時刻付き根拠3件→検索 PASS |
| 中断/再送写真 | 部分PUT中断→raw未作成→UPLOAD_INCOMPLETE→同一receipt完全再送→Vision OCR→ready→検索 PASS |

全5資料でlist、lecture summary用context、質問「根拠資料」のretrievalがPASS。
音声根拠: `0–2660ms`、`3040–9020ms`、`9440–12340ms`。
実ユーザー資料・個人録音・個人情報は使用していない。

catalogはdefault DBの`classes/00002`を参照。syllabus URLの`YR=2026`から`courseOfferingId=2026:00002`を決定し、年度/学期/URL/授業情報snapshotを保持。
本文・chunks・usageは`aogaku-ai`に存在。default DBの対応source/chunksは不在。pilotのdefault AI usage/periodsは再送後も変更前と同一。
原本/派生物は`ai-inputs/aogaku-ai/` / `ai-derived/aogaku-ai/`配下。音声原本は成功時の既存pipeline処理に従い削除。

## duplicate / upload retry

- 同一clientRequestId再受付は同一source ID、readyを返す。duplicate PASS。
- 部分PUTはobject未作成、CompleteはUPLOAD_INCOMPLETEで拒否。
- aiRetrySource成功後、harnessがupload URLを期待する誤りで一時停止。稼働APIは状態だけを返す。
- owner・awaiting_upload・raw不在をread-only確認し、iOSと同じ同一request IDのaiCreateSourceでreceipt/URLを更新。成功済みaiRetryや中断PUTを再実行せず、残る完全PUT→Complete→OCR/検索だけを完了。
- 元停止結果は`build/production-phase5a/retry-harness-stop/`に保存。backend source変更なし。

## 使い捨てAuth cleanup

登録hash・production token・pilot除外を照合した1件だけAdmin APIで削除。
post-check: Auth不在、named source/membership 0件、named/default usage/periods不在、raw/derived object 0件。
復活防止の最小named owner tombstoneとdefault deletion fenceは意図どおり保持。資料・本文・fixtureは残っていない。
pilot accountと他ユーザーデータを削除していない。Phase 5bの削除競合E2Eは未実施。

## 最終audit

- **25/25 installed full source manifest一致**。既存13 Functionsのsource / updateTime / metadataは不変。
- AI12件manifest SHA: `34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`。package-lockも同一。
- env-only更新のnative build ID/source generation/updateTime/revisionだけを、source全文一致＋protected metadata不変の条件で許容。
- DB、Rules、indexes/fieldOverrides、Secret metadata/version、lifecycle、Eventarc、project/SA/bucket IAM不変。
- queue RUNNING。Scheduler **PAUSED / lastAttemptTimeなし**、通常実行なし。
- sharing OFF、background private、許可UID 1件。unexpected driftなし。
- ローカルguard/read-only retryテスト **14 PASS / 0 FAIL**。

## fixtures / 残条件

pilot資料5件は保持。後続の別承認でregistryとownershipを照合してcleanupする。
source ID prefix: memo `d5fbcb46f2c6`、photo `12a954d13767`、PDF `fced9f12f684`、audio `2a76307080b2`、retry photo `e5b3f502da57`。
完全なID/clientRequestId/owner configはGit除外のregistryに保存。

Phase 5b: 削除開始時の新規受付拒否、削除後遅延worker拒否、Storage finalize遅延upload除去、Scheduler reconcile、長時間録音、provider障害注入、quota限界。
sharing ON・一般開放・App Store公開・GitHub統合も別承認事項。ここで停止。

## 証跡 / 変更ファイル

Git除外`build/production-phase5a/`: `resume-preflight/`（fresh25 source＋旧baseline/approval/journal保存）、`execution.json`、`gates.json`、`e2e.json`、`final/result.json`、`final/data-boundary.json`、`outsider-cleanup-proof.json`。
前回停止報告は`PHASE5A_SAFE_STOP_RESULT.md`に保存。

追加/変更: `scripts/resume_production_phase5a.cjs`（fresh resume）、`scripts/deploy_production_phase5a.cjs`（fresh artifact fingerprint）、`scripts/production_phase5a_e2e.cjs`（実schema/receipt再送契約）、`scripts/production_phase5a_auth.cjs`（登録済み非許可UID cleanup）、`scripts/audit_production_phase5a_outsider.cjs`（cleanup照合）、`scripts/audit_production_phase5a.cjs`（実Run revisionを含む最終audit）、本報告と旧報告保存。
アプリ/backend実装sourceは今回変更せず、source deploy/全Functions deployなし。commit/push/mergeなし。

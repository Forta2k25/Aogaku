# Phase 4 完了報告 — closed deployment

判定: **PHASE4_COMPLETE**。最終read-only audit完了: 2026-10-07T04:37:07.703Z（2026-10-07 13:37 JST）。Phase 5 readiness blockerは0。ただしPhase 5の承認・内部UID確定は未実施で、有効化はしていない。

## 対象と変更範囲

本番project `forta-aogaku` / number `505828754933`、bucket `forta-aogaku.firebasestorage.app`（US-CENTRAL1）、Release Bundle ID `com.forta2k25.Aogaku` を再照合。named DB `aogaku-ai` は Native / asia-northeast1 / delete protection ON、全面client deny、必要indexes READYのまま。

今回CREATEしたのは `aiReconcileInputs` / `aiRejectLateUpload` の2件だけ。成功済み10件は再CREATE・再deploy・更新していない。`aiProcessSource` の既存Run invoker / Function限定metadata bindingには書き込みを行っていない。

| Function | 状態 | trigger | updateTime (UTC) |
|---|---|---|---|
| aiCompleteSource | ACTIVE | Callable HTTPS | 2026-10-07T01:09:13.057734690Z |
| aiRetrieveContext | ACTIVE | Callable HTTPS | 2026-10-07T01:57:13.950479792Z |
| aiReconcileInputs | ACTIVE | Scheduler HTTPS | 2026-10-07T04:20:16.416964246Z |
| aiProcessSource | ACTIVE | Tasks HTTPS | 2026-10-07T02:50:48.759167083Z |
| aiCreateSource | ACTIVE | Callable HTTPS | 2026-10-07T01:05:42.041243896Z |
| aiListSources | ACTIVE | Callable HTTPS | 2026-10-07T01:14:54.199119370Z |
| aiGetSource | ACTIVE | Callable HTTPS | 2026-10-07T01:12:01.146639576Z |
| aiGetEvidence | ACTIVE | Callable HTTPS | 2026-10-07T01:44:09.072151942Z |
| aiRetrySource | ACTIVE | Callable HTTPS | 2026-10-07T01:47:59.794532874Z |
| aiDeleteSource | ACTIVE | Callable HTTPS | 2026-10-07T01:54:09.740232344Z |
| aiUpdateSource | ACTIVE | Callable HTTPS | 2026-10-07T01:50:58.826030128Z |
| aiRejectLateUpload | ACTIVE | Storage finalized / Eventarc | 2026-10-07T04:24:21.647703844Z |

12件すべて Gen2 / Node22 / asia-northeast1、runtime SA `aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com`。全12 installed full source manifestは9ファイルすべて承認artifactと一致:

`34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`

## IAM / queue / Scheduler / Eventarc

- workerの既存Run resource `projects/forta-aogaku/locations/asia-northeast1/services/aiprocesssource` のruntime SA `roles/run.invoker` と、Function resource限定 `projects/forta-aogaku/roles/aogakuAIFunctionMetadata` をGETで確認。変更なし。
- 新規Run resources `projects/forta-aogaku/locations/asia-northeast1/services/aireconcileinputs` / `projects/forta-aogaku/locations/asia-northeast1/services/airejectlateupload` に、同runtime SAの `roles/run.invoker` だけをそれぞれ1回加算。project-wide IAM追加なし。
- queue `projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource` は **PAUSED**、設定・IAM不変。
- Scheduler `projects/forta-aogaku/locations/asia-northeast1/jobs/firebase-schedule-aiReconcileInputs-asia-northeast1` を1回CREATE後、直ちに1回PAUSE。state **PAUSED**、`lastAttemptTime` なし。`every 15 minutes` / UTC / OIDC runtime SA / 東京の実Run URIを照合。resume/runなし。
- Eventarc `projects/forta-aogaku/locations/us-central1/triggers/airejectlateupload-082019` は `us-central1`、filterは本番bucket + `google.cloud.storage.object.v1.finalized`。destinationは live APIの `destination.cloudFunction` が東京の `aiRejectLateUpload` を明示し、そのFunctionの実Run resourceも東京であることを確認。Cloud Run形式のdestinationを勝手に要求する比較は使用しない。
- transport topic `projects/forta-aogaku/topics/eventarc-us-central1-airejectlateupload-082019-589`、subscription `projects/forta-aogaku/subscriptions/eventarc-us-central1-airejectlateupload-082019-sub-350`。Function metadata / Eventarc / bucket notificationのtopicを照合。
- handlerの厳密な `ai-inputs/aogaku-ai/...` 原本path判定を確認。avatars / users / ai-derived等の対象外prefixはFirestore・Storage I/O前にreturn。

## closed / 不変確認

- AI **12/12 ACTIVE**、runtime / memory / CPU / timeout / concurrency / SA / trigger / source契約一致。
- `AI_FIRESTORE_DATABASE_ID=aogaku-ai`、`AI_INPUT_ALLOWED_UIDS=[]`、`AI_SHARING_ENABLED=false`。default DB fallback禁止維持。
- 全12 Run IAMに `allUsers` / `allAuthenticatedUsers` なし。invoker IAMチェック無効化なし。
- 12件 × Run / cloudfunctions.netの匿名GET **24/24 HTTP403**。存在しないendpointの404を成功扱いしていない。
- 有効な本番/Dev user tokenは取得・実通信していない。Phase 4ではIAM privateによる拒否を確認し、user token単独で受付できる構成にはしていない。empty UID / closed worker / Scheduler no-opは既存exact artifact回帰でも確認。
- 既存13 Functionsのfull source / metadata / updateTime / IAM不変。既存10 AI Functionsのfull source / metadata / updateTime / Run IAMもfresh baselineから不変。
- default/named DB、Firestore/Storage Rules、default/named indexes・fieldOverrides不変。Secret metadata / version / binding不変。`GROQ_API_KEY` latestは **version 1 / ENABLED**、payload未取得。
- lifecycle / soft-delete 7日、bucket IAMのbinding・condition・version、その他既存IAM、API/SA inventory不変。user-managed SA keyなし。
- Auth fixtureや本番ユーザーデータの作成・変更・削除なし。通常OCR/ASRを有効化・実行していない。

## 停止と監査修正を含む経緯

Function CREATE・staging・operation・source照合・new resource IAM・Scheduler CREATE/PAUSEはすべて成功し、mutationの自動/手動再実行は0。

`aiRejectLateUpload` post-checkはbucket `metageneration` **3→4**の比較でSTOPPEDになった。bucket IAM etagも `CAM=`→`CAQ=`。bucket設定とIAM内容には差分がなく、今回のEventarcが作成した唯一の `OBJECT_FINALIZE` notificationのID/topicが実triggerと一致した。[Google仕様](https://docs.cloud.google.com/storage/docs/pubsub-notifications)はnotificationの追加/削除でbucket metagenerationが増えると定めている。

監査を独立したread-only実装に分離し、今回のcounter/etag差分だけを正しいnotification・destination・topic・payload・event type・単一inventoryの証拠とともに検証。bucket lifecycle/IAM binding/condition/version等の変更、追加notification、別topic、別destination、別SA、想定外counter/etagは引き続き拒否する。baselineやSTOPPED実行記録は変更せず、比較用コピーだけで既存のstrict protected-state比較を実行した。

最初のread-only監査は、Eventarc filter配列の応答順序だけが変わった最終比較で停止。raw証拠を保持し、filter順序だけを正規化（値・その他metadataは厳密比較）して全25 installed sourcesとprotected-stateを再取得・再監査した。最終auditはPASS。元のSTOPPED journalを成功に書き換えていない。

予期しない実リソースdrift、未完了mutation、最終partial successはなし。履歴上の比較エラーは保存済み。

## read retry / 検証

- transient read: `run.googleapis.com` GET `/v1/projects/forta-aogaku/locations/asia-northeast1/services/aigetevidence:getIamPolicy` のattempt 1がHTTP503、attempt 2がHTTP200。発生1件・追加read 1回。最終再監査では追加transient errorなし。
- 最大5回read-only retryとexponential backoffを使用。CREATE/PATCH/SET IAM/Scheduler/PUT等はretry対象外。mutation後に読めなくてもmutationを再実行しない。
- 今回追加/修正したnotification audit + read retry tests: **13/13 PASS**、fail/skip 0。
- 継続前に実行済みで保持した同artifactの検証: TypeScript build PASS、domain **13/13**、Emulator **50/50**、closed/deploy/read guards **16/16**、production/named/rollout safety **23/23**。Functions実装sourceを変更していないためこれらは再実行せず、証拠を維持。completion/emulator.logは同検証ログの保存コピー。

## Phase 5へ残す事項

Phase 4 blocker **0**、Phase 5へ進む技術blocker **0**。ただし次の操作は未承認・未実施。

1. Phase 5の別承認と内部テストUID 1件の確定（private local configのみ）。
2. 別承認で9 CallableのHTTP IAM ingressを調整し、Firebase Auth必須・そのUIDだけ許可。
3. queue / Schedulerの別承認resume、共有OFF継続。
4. 個人利用の写真/PDF/メモ/録音→OCR/ASR→保存→根拠検索E2E。
5. Phase 3bからdeferredの「削除中の新AI受付拒否」「遅延worker拒否」「Storage finalizeによる遅延upload除去」。受付・worker・triggerは本番に実在するが、実UIDを用いた3項目のE2Eはまだ実施していない。

Phase 5 / UID追加 / public ingress / sharing ON / queue・Scheduler resume / lifecycle追加 / GitHub push・merge / App Store公開 / Aogaku-clean変更なし。ここで停止。

## ファイル / private evidence

追加したローカルsource:

- `scripts/audit_production_phase4_complete.cjs`: 本番mutationを持たない最終監査。承認済みnotification副作用の限定検証、全25full source、全12private/closed/匿名拒否、immutable protected-state、元journal/baseline不変確認。
- `scripts/test_production_phase4_notification_audit.cjs`: notification副作用以外のdrift拒否、IAM/lifecycle不変、filter順序、read-only性の回帰テスト。
- 本報告 `docs/ai-input/PHASE4_COMPLETE_RESULT.md`。

Git除外・private（directory700/files600）証拠:

- `build/production-phase4-completion/`: fresh23 baseline/approval、2件成功receiptとSTOPPED原記録、source ZIP/manifest、new scoped IAM、Scheduler paused、notification調査。
- `build/production-phase4-completion-audit/`: 最初のread-only監査のraw before/afterとfilter順序によるerror。
- `build/production-phase4-completion-audit-final/`: **closed-live.json = PHASE4_COMPLETE**、再取得before/after、全25 installed ZIP、notification proof、Eventarc。
- `build/production-phase4-retry/read-events.jsonl`: 安全なread service/method/path/attempt/status/error kindの記録。query/header/token/Secret payload/signed URLを保存しない。

以前のDev / Emulator / Phase 3b / Phase 4停止記録を維持。commit / push / mergeなし。

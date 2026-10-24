> 2026-10-06: Phase2bはnamed database分離案へ変更。最新構成は [NAMED_DATABASE_ARCHITECTURE.md](NAMED_DATABASE_ARCHITECTURE.md) を参照。本書のdefaultへのAI Rules追加案・過去receiptは本番反映に使用しない。

# 本番反映の最終手順・phase別承認（2026-10-06）

> 2026-10-07の最新状態: [PHASE3A_PRODUCTION_RESULT.md](PHASE3A_PRODUCTION_RESULT.md)。Phase 1・2・3aは完了、Phase 3bは未実行。以下の「承認待ち」「未実施」は計画作成時点の履歴。次Phaseには新metadata / artifactと別承認が必要。Phase 3aの旧AIは3-callable slim artifactを個別source-only PATCHで反映し、Secret/IAM/runtimeを保持した。

> 最新の実行状況: [PHASE1_COMPLETE.md](PHASE1_COMPLETE.md)。Phase 1は追加承認後の残作業・post-checkを含め完全成功。Phase 2への追加承認待ちで停止。以下は実行前に確定したrollout計画・検証記録。

現在は **deploy承認待ち**。コード/構成上の未解決をローカル検証で解消した。実際の本番反映・本番E2Eは未実施であり、installed gateを反映済みに書き換えていない。本番内部UIDは未指定なので、cohortは空配列＝全員遮断のまま。UID指定はPhase 5だけの実行条件で、閉じた構成の準備を妨げない。

この手順を準備した前ターンは本番metadata GETだけを行った。本番deploy・データ書込み/削除・IAM/API変更、Secret payload取得、GitHub push/merge、Aogaku-clean変更、アプリ公開はない。元の未commit AI/年度snapshotと以前のDev結果を保持している。

機械可読の計画は `Config/Production/rollout.phases.json`、IAMは `iam.plan.json`、queueは `queue.create.json`。生成artifact・認証・approval・生metadataは `build/` 等のGit除外領域に分離する。

## 解除条件と手段

| blocker | コード/構成で用意したもの | 実行時に解除する条件 |
| --- | --- | --- |
| 削除3 hook未反映 | 対象3のみ選択する既存default codebase専用wrapper。回収した実コードへhelper接続済み | Phase 3bの承認付き更新→稼働ソース・世代・SA・Secret差分一致→内部使い捨てUIDの削除E2E |
| 旧quotaの再生成防止未反映 | 旧ask/ASR/reactionPaperの消費・返金transactionとAuth状態guard | Phase 3aの3関数だけ更新→元Secret version1保持→実ソース一致、旧契約回帰 |
| 内部UID・一般利用者遮断 | closed/pilot profile、空配列default、全9 callableとworkerのserver gate、共有hard OFF、直接Rules拒否 | Phase 5で本番Auth UIDを私有ファイルへ設定→一般/匿名/Dev token/直接workerの拒否確認 |
| IAM/API未準備 | exact target・最小IAM・API差分・paused queue・配送設定の計画 | Phase 1の承認、Phase 4のresource-scoped invoker等の追加と検証 |
| deploy許可未発行 | phase/group/profile/artifact/現行inventory/versionに結び付く短命approval。全Functions/削除/世代移行拒否 | phaseごとの人間による明示承認。本書は実行の承認ではない |

indexes/Rulesのgateは旧hookの**installed状態を要求しない**。AI Functionsのclosed bootstrapは内部UID確定を要求しないが、旧削除/旧quota稼働版確認とその他reviewを必須にする。pilotは全gates＋非空UIDを要求する。実行時にsnapshotを読み直しても承認hashが無意味に変わらないよう、hashから監査用readAtだけを除外し、実リソースのupdateTime/設定変化は検出する。

## 今回読み取りで確認した本番状態

- project `forta-aogaku` / number `505828754933` / bucket `forta-aogaku.firebasestorage.app` / Release bundle `com.forta2k25.Aogaku`。
- bucketはUS-CENTRAL1、Functions/Firestoreはasia-northeast1。
- 有効APIとの差分は **cloudtasks.googleapis.com / cloudscheduler.googleapis.com / vision.googleapis.com** の3つ。その他の計画APIは現時点で有効。
- 専用AI runtime SAと専用account-deletion SAは未作成。
- Tasks/Scheduler GETはAPI未有効の403だった。これはqueue/job不存在の証明ではない。API有効後の再読取りで名前衝突・既存所有者を確認してから作成する。
- US-CENTRAL1のEventarc trigger一覧は現在0件。新triggerはSDKのaiRejectLateUploadから1件生成し、Pub/Sub配送もSDK管理とする。重複trigger/topicを手作業で作らない。
- 対象6旧Functionsは全てdefault codebase。旧AI3はGen1 Node22/App Engine default SA。削除v2×2はNode18/Compute default SA、Auth削除はGen1 Node18/App Engine default SA。
- 旧AIのOPENAI/GROQ bindingは各version1。削除v2の未使用IMPORT_API_KEYはversion2、Auth triggerはsecretなし。payloadは取得していない。

## 旧6 Functionsの更新差分と復旧版

AI12 wrapperとは別に `firebase_legacy_production.py` を使用する。packageには対象6のみをexportし、deploy対象はquota3またはdeletion3だけ。default codebaseを維持し、友人通知、import、reindex、wipeなどは選択しない。関数削除、generation変更、全Functions deploy、--forceは常に拒否する。

| 対象 | 維持 | 更新差分 |
| --- | --- | --- |
| askCourseAI / generateReactionPaper | Gen1、Tokyo、Node22、256MB/120秒、現行SA、API出力・model・上限、OPENAI version1 | Auth/owner検査、消費・返金transactionのtombstone検査。稼働版にはchat永続化がないため追加しない |
| transcribeLectureAudio | Gen1、Tokyo、Node22、512MB/540秒、現行SA、Groq/OpenAI処理とraw cleanup、両Secret version1 | 同じquota guard |
| preDeleteCleanup / deleteAccountServerSide | Gen2、Tokyo、1GB/540秒、現行CPU1/max20、既存cross-link/avatar/username処理 | Node18→22/SDK6、専用削除SA、再認証5分以内、Auth前helper、不要IMPORT binding除去、version付き事前応答、nested tree/privateUsage/旧raw完全cleanup |
| onAuthUserDelete | Gen1 Auth user.delete、Tokyo、現行retryなし | Node18→22/専用削除SA、helperと追加cleanup。作業量増加に備え256MB/60秒/max3000→512MB/540秒/max20。処理継続はAI reconcileが補う |

Node18はdecommission済みで、そのまま再deployして戻す手順は使えない。[公式runtime表](https://docs.cloud.google.com/functions/docs/runtime-support)に基づき、原コードの動作をNode22/SDK6の明示v1互換入口へ載せた `rollback-before-pilot` を用意し、Emulatorで実行検証した。

- **AI受付前**: 原動作のNode22復旧版を、承認した同名3関数だけへ戻せる。メモリ等の互換設定は計画artifactに固定する。旧Secret bindingも同じversionに固定。
- **AI受付後**: 原動作版は削除helper/旧quota guardを失うので使用禁止。まずclosedに戻し、検証済み `safety-recovery` と削除継続処理を保持する。障害原因が安全helper自体ならguardを外さずforward fixを作って再検証する。
- Auth/資料の正常削除は不可逆。コードrollbackでデータやユーザーを復活させない。

Secret pinはCLI14.17.0専用preloadで、latest自動解決を既存の明示version照合に置き換える。versionが無効・missingなら停止し、rotationで修復しない。反映後は `verify_legacy_install.cjs` がSourceCodeGetで取得したZIPの**lib全ファイル・package/lock**を承認artifactのSHAと比較する。download URL/payloadはログに出さない。SDK metadataだけで「hook反映済み」と判断しない。AI12 deploy前にもこの検査を再実行する。

## Phase 1 — 不足API・最小IAM・専用SA・paused queue

**承認対象**: 不足3 API有効化、専用SA×2/custom rolesと計画bindingの追加、管理service agent準備、AI queueの新規作成・PAUSE。Secret値・版、Authユーザー、Firestoreデータは変更しない。

- AI runtime: Firestore datastore.user、Auth getのみのcustom role、Storage get/list/create/deleteのbucket role、queue enqueuer/taskDeleter、自身へのactAs/signBlob、Functions worker metadata GET、VisionのserviceUsageConsumer、Eventarc receiver。GROQ既存SecretへのAccessorのみ追加。
- 削除runtime: datastore.user、Auth get/delete custom role、Storage get/list/deleteのみ、AI queue taskDeleter。Vision・Secret・storage create/signBlobは付与しない。
- Tasks/Scheduler/Eventarc/PubSub/FunctionsのGoogle管理agentはそれぞれのserviceAgent roleを維持し、不足だけ追加。Storage agent `service-505828754933@gs-project-accounts.iam.gserviceaccount.com` にPub/Sub publisher。
- Cloud Build/deployerはruntimeと別。現在のbuild identityを読み直し、source/image/log/deployに必要な範囲だけ追加する。既存Editorを新runtimeへコピーしない。
- IAMはetag/version3で現行policyに加算。queue/Runへのbindingは対象resource作成後。UBLA・ACL・public IAMは変更しない。
- queueはTokyo `aiProcessSource`、PAUSED、concurrent3、retry4/min30s/max300s。作成bodyにはoutput-onlyのstateを含めず、作成直後に明示pause→GETでPAUSEDを確認する（queue.lifecycle.plan.json）。既存同名非AI queueがあれば停止。

**影響/リスク**: 既存Functionsのコードは不変。API利用・Cloud Build・Vision・Storage・Tasksには課金の可能性。権限反映遅延やsource/Artifact Registry不足で後続が失敗する可能性がある。

**直後確認**: project/number/bucket/bundle再照合、API3 enabled、SAキーなし、roleが計画と一致、同名queue所有者とPAUSED、IAM既存binding保持、既存Secret enabled/版不変。

**rollback**: APIを共有用途ごとdisableしない。未使用であると確認した今回追加bindingだけを新etagで除去。queueはpausedで保持。既存managed agent、SA、Secretを削除しない。

## Phase 2 — index追加 → READY → Rules追加

**承認対象**: 既存3 index＋AI1 index（計4）、fieldOverrides8保持。その後Firestore/Storage RulesへAI領域のclient denyだけ追加。

各subphaseに独立したapprovalが必要。index READYを確認してからRulesへ進む。`firebase_production.py --phase indexes|rules --profile closed` のみ使用。

**影響/リスク**: 既存lectureNotes、avatars、friends、catalog/reviews/search等の条文と既存indexはそのまま。構築中の負荷/課金と、監査後に他者がRulesを変更するdriftがリスク。

**直後確認**: 全4 index READY/override8不変、active Rules全文がbaseline＋指定denyだけ、既存権限回帰、AI direct read/write不可。ユーザーデータを使う本番回帰は内部fixtureの別承認範囲に限定する。

**rollback**: AI index/deny追加は基本残す。実権限回帰があれば、直前の承認済みRules releaseへdriftを確認して戻す。index/override削除、--force、古いローカルRulesでの上書きは禁止。

## Phase 3a / 3b — 旧quota3 → 旧削除3の個別更新

**承認対象3a**: askCourseAI/transcribeLectureAudio/generateReactionPaperの同名更新。**承認対象3b**: preDeleteCleanup/deleteAccountServerSide/onAuthUserDeleteの同名更新。それぞれ別approvalで停止点を設ける。

**影響/リスク**: 現行App Store版には旧AI3関数の利用導線がなく、一般ユーザー向けAIは未公開（利用者から2026-10-06確認）。3aは公開UIへの直接影響はないが、存在する本番endpointの直接利用・内部利用への影響と契約維持は確認する。3bの削除3関数は既存ユーザーの削除経路へ影響し得るため、従来どおり慎重に扱う。quota guardは既存上限や出力を維持するがAuth検査を追加する。削除はnested残存データも消し、再認証要求・runtime/SA・Auth cleanup並列数が変わる。低トラフィック時に反映し、既存ログ/失敗率を確認する。友人通知関数のコードを更新せず、削除由来の通常eventは既存通り発生する。

**直後確認**: 各3関数のupdateTime/generation/region/runtime/SA/Secret版、ZIP全ソース一致、他Functionsのversion不変。内部UIDによる旧AI/ASR/quota、再認証、使い捨てUIDで削除3経路を確認する。これらの本番quota/データ書込み・削除もphase承認へ明記する。実ユーザー削除でテストしない。

**rollback**: 前述のNode22復旧版を対象3だけへ使用。まだAI受付ゼロの確認を必須にする。3a成功/3b失敗ならAI受付は閉じたまま停止し、3aを無理に巻き戻さない。コード復旧後もSecret版/他Functions不変・旧契約を再確認。

## Phase 4 — AI12を全員遮断して反映・配送/IAMを確定

**承認対象**: aogaku-ai codebaseの12関数だけをclosed profileでdeploy。既存Task queue設定を維持、Scheduler、US Eventarcと管理Pub/Sub配送、必要なRun invoker bindingを含む。

- Functions/FirestoreはTokyo、Storage finalizeのEventarcは **us-central1**、bucket filterは本番bucket完全一致。destination Cloud RunはTokyo。SDKが生成した実名/URIをGETで特定してbindする。
- 2026-10-07 Phase 4の承認条件により、Callableも含めAI12すべてprivate。worker/reconcile/finalizeのみ実resource確認後にruntime SAへRun invokerを加算。公開HTTP入口を自動付与するCLI deployはclosed profileでは禁止し、`scripts/deploy_production_phase4.cjs` の12件限定CREATE wrapperを使用する。Phase 5のiOS Callable接続方式は別承認で確定する。
- 既存queueはGETでPAUSEDと設定不変を確認し、Phase 4ではqueueを更新しない。queue purge/delete/resumeは禁止。
- 新Schedulerはdeploy時に作成/有効化され得るため、直後に対象jobだけpauseしてstateを確認。間のtickでもclosed handlerがDBアクセス前にreturnする。Job OIDCはAI runtime SA、destinationはreconcile URI。

**影響/リスク**: 旧関数名を置換しない。bucketの全finalizeがevent配送対象になるが、handlerはai-inputs以外を早期returnする。既存avatars/旧音声には処理を加えない。US→Tokyo配送・原本転送の遅延/料金、agent IAM反映待ちに注意。

**直後確認**: legacy6実ソース一致、AI12一覧/SA、link API除外、empty UID/共有OFF、9 callable全拒否、private invoker、queue PAUSED、Scheduler PAUSED、EventarcのACTIVE/filter/location/destination/IAM。

**rollback**: closed・pausedのまま停止。12関数の安全artifactへ同名更新し、削除worker/finalize/reconcileと必要IAMは残す。全Functions deployや初回関数削除で戻さない。

## Phase 5 — 指定UIDだけ有効化・内部本番E2E

**承認対象**: 本番Auth UIDの存在読み取り、私有 `Config/firebase-production.local.json` に `{ "allowedUIDs": [実UID] }` を保存してpilot profileのAI12へ反映。その後AI queueとSchedulerだけresume。架空資料のupload/解析/保存/検索と、使い捨て内部Auth UID/資料の削除テストを明示承認する。

UIDはチャット経由でも秘密ではないが、ソース/commitへ入れない。パスワードや鍵は要求しない。本番UID未指定の現在はこのphaseを実行できず、全員拒否を維持する。

**一般利用者遮断の確認**:

- 全9 callableが正しく認証した非allowlist UIDを受付前にAI_INPUT_NOT_ENABLEDで拒否。verified membershipでも変わらない。匿名・Dev project tokenは認証で拒否。
- cohortから外れたownerはqueue受付/worker処理/publishも拒否。直接Firestore/Storageはownerを含めdeny。worker/reconcile/finalizeの無権限HTTPはIAMで拒否。
- 内部UIDの本人資料だけ検索可、共有は本番でhard OFF。UID単位の機能許可はFirebase SDKが検証したauth.uidに対して評価し、request bodyのUIDでは決めない。

**E2E**: 写真→Vision OCR、PDF本文＋ページOCR、メモ、録音→Groq→時刻、本人根拠検索、再送、重複、upload/解析中削除、遅延upload、3アカウント削除経路、旧quota返金の再生成防止。授業はURL YR＋5桁doc ID/年度snapshotを使い、code/名前/現在年へfallbackしない。

**影響/リスク**: 指定UIDに限り新入力を有効化。旧AI3関数のendpoint契約は維持する。現行公開アプリには旧AIの利用導線はない。ここからAI資料の実保存/削除が起きるため、原動作rollbackは禁止になる。

**rollback**: closed profileに戻し、queue pause。安全な削除/finalizeとScheduler cleanupは継続・必要時再開。受付を閉じても発行済み署名upload URLは最大10分残るので、対象資料の個別停止/削除は追加承認で行う。新規の一般利用者に署名URLは発行されない。既存承認済み削除の続きを途中停止しない。

## Phase 6 — E2E成功後、AI音声lifecycleだけ追加

**承認対象**: 現行lifecycleへ `ai-inputs/` かつ `.m4a` のage2削除を1 rule追加。既存users/音声age1とsoft-delete7日を維持。

**直後確認**: 最新lifecycle/metagenerationを再取得、diffは1 ruleだけ、`ifMetagenerationMatch`付きPATCH成功、再読取り一致。古い全bucket設定のsetで上書きしない。

**影響/リスク**: AIの未完了音声原本を期限で消すため、長く停止した解析は再uploadを要する。既存音声・写真/PDF・派生物の期限は変更しない。

**rollback**: 新しいlive lifecycleをmergeして今回のruleだけを除く。別承認と新metagenerationを使用。既に期限消去されたobjectを復旧したと扱わない。

## phase停止・partial deployの共通条件

各phaseは前phaseのpostcheck成功後だけ進む。CLIが部分成功したら、成功した名前/版を記録し、失敗分だけのretry計画を再承認する。wrapperは固定3/12対象で再実行してよいが、--forceで何かを削除しない。異なるcodebase/generation、未知の既存queue/job、Secrets/IAM/Rules/index drift、SourceCodeGet不一致、一般UIDの受付、旧機能回帰失敗なら次phaseを停止する。

実行approvalはphase/group/profile、正確なnamed replacements、artifact SHA、現行inventory SHA、expectedUpdateTimes、1時間未満の期限に限定する。metadataは5分以内。CLI14.17.0/Node22を固定し、CLI変更時にはguard再検証。承認sessionは実行中だけ作成して終了時削除する。全phaseを包括承認したとみなさない。

main merge/PR merge/App Store公開、一般ユーザー展開、共有ONは本計画の承認に含めない。実機の長時間録音・着信・強制終了・圏外復旧、負荷/保持方針・監視体制は公開前の別条件。

## ローカル最終検証

- TypeScript build、domain単体13/13。
- Emulator38/38、skip0: 旧機能実ソース比較、削除再生成防止、全9 callable/workerのcohort拒否、Node22更新/rollback artifact実行。
- Python本番安全11＋phase/rollback5、Node CLI/Secret/read-only7。Secret version pin、強制queue pause、purge/delete禁止、phase gate、snapshot hash安定性を含む。
- 直前のDev削除3経路・Simulator4件・実Vision/Groq、通信/削除/再試行/共有OFF成功を保存。今回はその結果を破棄せず、production固有の構成をローカルで追加検証した。
- 本番の実deploy、実installed sourceの照合、実配送と本番内部E2Eは**承認後**に実施する。ローカル合格を本番動作完了とは呼ばない。

## 参照した公式仕様

- [Function管理/対象限定deploy](https://firebase.google.com/docs/functions/manage-functions)
- [Node runtimeの更新/廃止](https://docs.cloud.google.com/functions/docs/runtime-support)
- [Eventarc sourceとdestinationのregion](https://docs.cloud.google.com/eventarc/docs/understand-locations)
- [VisionのADC/IAM認証](https://docs.cloud.google.com/vision/docs/authentication)

原実装回収・削除helper・前回のE2E証跡は [ACCOUNT_DELETION_READINESS.md](ACCOUNT_DELETION_READINESS.md)。その時点のproduction blockersは本手順で解消方法とartifactを確定し、実反映/承認待ちに移行した。

最終準備の機械検証: `python3 scripts/final_rollout_readiness.py`。`build/final-rollout-readiness.json` はコード/構成blocker 0と実行待ち条件を別々に記録する。このreportはapprovalではなく、実行gateを解除しない。

Cloud Tasksのstateはoutput-onlyでcreate/patchでは変更できない。[公式Queue仕様](https://docs.cloud.google.com/tasks/docs/reference/rest/v2/projects.locations.queues)に合わせて明示pauseとGET証明を使用する。

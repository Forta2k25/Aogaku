> 後続の最終準備: [FINAL_PRODUCTION_ROLLOUT.md](FINAL_PRODUCTION_ROLLOUT.md)。phase別wrapper/rollback/遮断・反映手順を整備し、deploy承認待ち。本書は前回検証時点の記録。

# アカウント削除連携と本番導入gateの確認（2026-10-06）

作業ブランチは `codex/ai-input-main-integration`、HEADは `d3f56c6aeacb24f8c23a0c36c77d1feca29e230a` のまま。未commitの年度別ID・snapshot・本番準備・削除連携を維持。main基点は `9d596f7b421e81df6776d4d337eb4c650231f371`。本番へのdeploy、データ書込み/削除、IAM/API変更、Secret payload取得、GitHub push/merge、Aogaku-clean変更、アプリ公開は実施していない。

## 回収した稼働版の実ソース

Git履歴・remote・既存ローカルコピーの確認では削除3関数が揃わなかった。Cloud Functionsのmetadata GETと、公式の読み取り専用 `generateDownloadUrl`（SourceCodeGet権限、POST）から署名済みZIPを取得。署名URLはメモリだけで利用し、ログ/ソースへ保存せず、Secretや利用者Storageを読まない。取得前後のupdateTimeを照合し、Gen1はversionIdも指定した。

`functions/recovered/deployed/provenance.json` に9関数の取得版、runtime/generation/updateTime、ZIPと実行ソースのSHA256を記録。秘密を含まない実コードだけを保存し、元ZIP/取得元URIはignoredなprivateディレクトリへ分離した。

- `aad2425fe638`: 稼働中 `preDeleteCleanup` / `deleteAccountServerSide` / `onAuthUserDelete`。原版はNode18、v2 callable×2＋v1 Auth trigger。import/wipe/index/Remote Configなどの無関係なexportは連携packageに含めない。
- `12ed370d671b`: 稼働中 `askCourseAI` / `transcribeLectureAudio` / `generateReactionPaper` / 友人通知3関数。同じ実コードのSHAを9関数それぞれのmetadataから照合済み。
- `functions/recovered/04cfb4a` は歴史版の比較資料として維持するが、稼働版の証明には使わない。現在のaskCourseAIはcourseChatsへの会話保存を行わず、歴史版と仕様が異なる。

## 削除helperの正式な接続

`functions/src/legacy-account/index.js` は回収した削除実装から対象3 exportと共通cleanupを抽出したadapter。3関数すべてが `beginAIAccountDeletion(uid)` を呼ぶ。

1. `preDeleteCleanup`: UID一致と5分以内の再認証を確認し、Auth削除前にAI owner tombstoneを確定、受付停止・追跡Tasks取消・原本/派生物/本文削除。`{ok:true, aiAccountDeletionVersion:1}` を返す。
2. `deleteAccountServerSide`: 同じhelperをAdmin Auth削除前に呼ぶ。旧友人リンク・avatar・username cleanupを保持し、Auth削除後にはusers subtree全体/privateUsage/旧音声uploadを再帰削除。
3. `onAuthUserDelete`: Gen1 Auth triggerを保持し、Auth直接削除でもhelperと旧cleanupを実行する。

25資料単位の削除はcursorで再開する。大量資料/一時障害時もowner tombstoneにより受付・根拠取得・遅延worker公開を先に拒否し、reconcileが後処理を継続する。最小UID/source tombstoneは復活防止用に残し、内容は残さない。Storageの既存soft-deleteによる保持versionは現行保持方針の対象で、物理即時完全消去の保証とは区別する。

`functions/src/account-deletion-entry.ts` の独立packageは対象3だけをexport。Devでは `aogaku-account-delete` codebaseへ個別deploy済み。AI12本番packageのallowlistを拡張していない。Node22/SDK6への更新候補でもGen1/Gen2と東京regionを保持し、IMPORT_API_KEYなど削除に不要なsecret bindingを除外した。これは本番への反映前に個別レビューが必要な差分。

## 旧quota再生成防止

`functions/src/legacy-ai/index.ts` は稼働版12edのprovider、入出力、上限、友人通知の仕様を保った更新候補。旧ask/ASR/reactionPaperのquota消費前にAuth/owner状態を検査し、消費・返金transaction内でもowner tombstoneを読み、削除と競合するとwriteを拒否する。削除後のprovider失敗から返金してもprivateUsageを作り直さない。

この候補はroot index/本番AI12packageにexportしていない。本番の旧3 AI関数へは別途明示承認の対象deployが必要。旧quota writerを未更新のまま、新AIの削除連携だけで完全な再生成防止が成立したとは扱わない。wrapperには `legacyQuotaDeletionGuardsIntegrated` を追加required gateにした。

## 端末側

`AuthManager.deleteAccount` は再認証後にUIDのupload runner/sessionを停止し、事前削除のversion付き成功応答を確認してからAuthを削除する。旧/未接続cleanupへAuthだけ削除するfallbackはない。準備失敗時はfail-closedでpauseを維持し、データは削除しない。

成功後、LocalSourceStoreと会話/添付/raw files、UID別cache、録音中/復旧receipt、授業画面・資料一覧のin-memory stateを消去。永続削除markerにより保持済みstore参照やアプリ再起動、遅延保存からの再生成を拒否。他UIDの資料を維持する。

## 検証結果

- iOS Simulator Debug build: **BUILD SUCCEEDED**。
- TypeScript build / domain単体: **13/13 PASS**。
- 本番統合Rules＋旧機能＋削除Emulator: **35/35 PASS、skip 0**。回収した稼働版そのものとadapterを同じfixtureで比較。旧ask/ASR/reactionPaperの正常・返金・削除中返金、友人通知の申請/承認/重複/取消、旧削除cleanup、25件超の再開を含む。
- Provider/FCM/signing/Auth/Tasks transportはEmulatorで置換し、許可したstub以外のクラウド通信を拒否。旧AIの実OpenAI通信や実端末pushを検証したという意味ではない。
- Devの削除E2E: **事前削除→client Auth、server側削除、Admin直接Auth削除の3/3 PASS**。実際の10分後Cloud Taskを作成し、削除後404で物理取消を確認。stale token、新規受付停止、original/derived/jobs/aiUsage/privateUsage/旧chat/nested note削除、署名URLの遅延upload除去を確認。
- Simulator Dev XCTest: **4/4 PASS**。実AuthManagerの削除/端末・UI memory消去、保持参照/再起動拒否、年度snapshot、写真/PDF/メモ/音声入力＋Vision/Groq＋本人根拠検索。
- 検証の再実行で既存Dev fixture UIDの日次quotaに達したため、新しい架空Dev UIDを用いる `--fresh-owner` を追加。既存quota、結果、認証fixtureを上書きせずに再検証する。
- Dev追加回帰: 通信中断/再送・upload中削除・解析中削除 **3/3 PASS**、aiRetrySource **PASS**、共有OFF（過去共有相当のfixtureも取得拒否） **PASS**。蓄積資料で検索の1ページ目に対象がない場合も、cursorを追って検証する。
- 環境分離/本番安全guard: Python **20/20 PASS**＋CLI/read-only guard **5/5 PASS**。
- 本番identity/Rules/index保持、Functions12 allowlist、削除/unsafe置換拒否、required gateとローカルpackage検査を再実行。本番監査snapshotを使うoffline planで、本番の変更操作はない。

実行ログとDev認証fixture/E2E結果はGit除外。最終機械可読の確認は `build/account-deletion-readiness.json` に保存する。

## production blockerと反映条件

**blockerは0ではない。** コードとDev/Emulatorでの削除連携・稼働版回帰の技術検証は通過したが、本番への更新をしていないため次は未達。

| required gate | 現在の状態 |
| --- | --- |
| accountDeletionHookIntegrated | コード/Dev合格。本番の削除3関数への対象限定反映・稼働版確認待ち |
| legacyQuotaDeletionGuardsIntegrated | コード/Emulator合格。本番旧AI3関数の個別安全更新・稼働版確認待ち |
| legacyRegressionApproved | 実ソース付き35回帰合格。最終レビュー/承認待ち |
| devPrivateProfilePassed | 共有OFFのDev検証合格。証跡レビュー待ち |
| iamAndApisReviewed | 分離した削除runtime最小IAMをDevで検証。本番IAM/API計画の承認と準備待ち |
| internalTestPlanApproved | 本番内部テスト手順の承認待ち |
| internalTestUIDsConfigured | 本番UIDの私有allowlistは未指定、空配列のため利用不能を維持 |
| productionDeploymentAuthorized | このターンは明示的に禁止。approval/session未作成 |
| retryPolicyReviewed | 固定CLI安全guard検証合格。反映時のレビュー待ち |

`Config/Production/account-deletion-maintenance.plan.json` と `iam.plan.json` は将来の別承認作業の計画だけ。AI12 wrapperから旧関数を自動置換・全Functions deployしない。回収したソース版・変更候補・回帰テストもartifact hashの対象とし、承認後の変更を見逃さない。

今後は対象限定の旧削除/旧quota更新手順（既存codebase/labels、世代、runtime、IAM、secret bindingを再照合）を別承認で確定し、本番内部UIDとIAM計画を承認してから、削除連携が実際に反映されたことを確認してAI12のgatesを満たす。main merge/アプリ公開は別条件。実機の長時間録音・着信・強制終了・圏外復旧、負荷/保持方針の確認も引き続き公開前の条件。

## 主な変更と保存

- 回収実ソース/provenance、`recover_legacy_sources.cjs`: 稼働版の証明と安全な回収。
- `legacy-account/index.js` / `account-deletion-entry.ts`: 対象3削除経路へのhelper接続。
- `legacy-ai/index.ts`: 稼働版のquota消費/返金の削除競合ガード。
- `deployed-legacy.test.cjs` / `recovered-legacy.test.cjs`、build/test設定: 実ソース・歴史版を区別した回帰。
- AuthManager、LocalSourceStore、SourceIngestionService、RecordingRecovery、NoteRecording、CourseDetail、SourceLibrary、Swift/XCTest: upload停止、UID別消去と復活防止。
- `prepare_account_deletion.py` / Dev wrapper/config / provision_dev / dev_e2e: Dev対象限定package、専用削除SA、3経路と実Tasks検証、quotaに依存しない再実行。
- 本番IAM/maintenance計画、production wrapper: 最小権限の分離、旧quota required gate、artifact hash。

staged差分はなく、commit/pushしていない。生成物node_modules/libは既存差分のままソースから分離。`../account-deletion-preparation-backup/` に開始時patch、既存結果のprivateコピー、最終source patch/archiveと今回結果を保存する。元AI実装・年度snapshot・以前のDev検証結果を保持している。

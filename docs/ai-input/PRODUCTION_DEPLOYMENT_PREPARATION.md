> 2026-10-06追記: 稼働版実ソース回収・正式な削除連携・最新検証と残gateは [ACCOUNT_DELETION_READINESS.md](ACCOUNT_DELETION_READINESS.md) を参照。以下の導入準備時点の検証結果は保存記録。

# 本番導入準備（2026-10-06）

作業ブランチは `codex/ai-input-main-integration`、main基点は `9d596f7b421e81df6776d4d337eb4c650231f371`。このターンでは本番へのdeploy・データ書込み・削除・IAM/API変更・Secret payload取得を行っていない。GitHub/既存Aogaku-clean/main/App Storeも未変更。読み取りは有効設定・登録アプリ・bucket/IAMなどのメタデータに限定。IAMの `getIamPolicy` は読み取り専用POSTであり、設定変更ではない。

## 対象と既存設定の保持

| 項目 | 本番専用値 |
|---|---|
| Project ID / Number | forta-aogaku / 505828754933 |
| bucket / location | forta-aogaku.firebasestorage.app / US-CENTRAL1 |
| default Firestore / Functions | asia-northeast1 |
| Storage Eventarc trigger | us-central1（東京の関数へ配送） |
| Release Bundle ID | com.forta2k25.Aogaku |
| runtime SA（新規作成案） | aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com |

`Config/Production/baseline.*` は今回読み取った**有効本番設定**。baseline.inventory.json に取得時刻・Rules release/ruleset・hash・既存13関数名を保持する。新しい本番定義は既存ファイルと分ける。

- Firestore: lectureNotes、classes/entries/circle/career、users/timetable/fcmTokens、friends/申請各表記の既存権限をそのまま保持。AIの5ルートに直接クライアントアクセス拒否を追加するだけ。
- Storage: avatarsの既存権限をそのまま保持し、ai-inputs/ai-derivedへの直接アクセス拒否を追加するだけ。原本はserver発行の期限・generation付き署名URLでuploadする。
- indexes: 既存3 composite（classes ngrams2+class_name、category+class_name、circle campus+popularity）と友人関連8 fieldOverridesを保持。AIのstatus+updatedAt indexだけ追加。`__name__` は暗黙の方向だけを省略し、Firebase CLI自身の比較処理でも一致を確認する。
- lifecycle: 既存users/の.m4aをage=1で削除するruleを保持。**案**はai-inputs/の.m4aだけage=2で削除するruleを追加。写真・PDF・メモ・派生物全体に一括TTLは設定しない。soft-delete 7日、ACL/UBLA、既存bucket設定は変えない。解析成功音声は既存処理で即時削除、未完了原本は24hでreconcileする。lifecycleは最後の取りこぼし用。
- bucket IAM、project IAM、defaultObjectACLにpublic principalがないことをメタデータで確認。今後public権限・基準設定のdriftがあればguardが停止する。既存オブジェクトごとのACLは取得していない。

Storage triggerとbucketの場所は一致が必要で、配送先Cloud Runは別regionに置ける。[Eventarc公式資料](https://docs.cloud.google.com/eventarc/standard/docs/run/route-trigger-cloud-storage)。SDK 6.4のStorage optionにはtrigger region指定がないため、production.tsでruntime regionを維持したままmanifestのeventTrigger.regionを設定。実SDKのloadStackで12 endpointを検証する。US→東京の転送・Storage・Vision・Functions/Tasks等の利用料金が発生し得る。

## 追加するリソースと権限

機械可読の案は `Config/Production/iam.plan.json`。このターンでは作成・付与していない。

| 主体/対象 | 必要権限・範囲 |
|---|---|
| 新runtime SA | Firestore datastore.user、Visionのserviceusage.services.use、Auth UID確認のfirebaseauth.users.getのみのcustom role |
| AI worker metadata | aiProcessSource関数上のcloudfunctions.functions.getのみのcustom role |
| AI Tasks queue | aiProcessSourceキュー上のEnqueuer + TaskDeleter |
| runtime SA自身 | Service Account User（Tasks OIDC） + signBlobだけのcustom role（署名URL）。秘密鍵発行なし |
| production bucket | objects.get/list/create/deleteのみのcustom role。bucket単位 |
| 既存GROQ_API_KEY | このsecretだけに新SAのSecret Accessorを追加。作成・version追加・上書き・rotationなし |
| AI3 worker services | 実際のservice名をmetadataで確認し、その3サービスだけにruntime SAのRun Invoker |
| Eventarc | runtime SAにEvent Receiver。Storage service agentにPubSub Publisher。配送triggerはus-central1 |
| Tasks/Scheduler/Eventarc/PubSub/Functions | 各Google managed service agentに自身のserviceAgent role。人間/runtimeにserviceAgent roleを与えない |
| build/deploy | runtimeと別の人間/CI主体。AI SAのactAsとFunctions deploy権限。API/IAM setupは別権限、Cloud Build主体とArtifact Registry/source bucket権限は実metadata確認後に限定 |

Firestore IAMはcollection単位に制限できないため、server側で使用するcollection/pathを限定する。Storageは既存UBLAがOFFのままなので、bucket単位custom roleとアプリのAI prefix制限を使用する。既存ACLを変更してprefix条件を可能にする操作は行わない。[Storage IAM公式資料](https://docs.cloud.google.com/storage/docs/access-control/iam)。

必要APIはiam.plan.jsonに列挙。既存のFirestore/Auth/Storageを新規作成し直さない。Tasks/Scheduler/Vision/Eventarc/PubSub/Functions/Run/Secret Manager/IAM Credentials/Cloud Build/Artifact Registry/Logging/Service Usage等の不足分のみを将来有効化する。既存のmanaged-agent bindingを消さず、policy version=3とetagで追加mergeする。queue/serviceへのbindingは対象リソース作成後に行う。

Runtime: callableはtimeout120s/maxInstances10、軽いcallable・scheduled・finalizeはgcf_gen1 CPU。workerは2GiB/1800s/maxInstances3、Task dispatch並列3。reconcileは15分ごと、timeout540s。finalizeはmaxInstances3、再試行ON。CPU quotaとcold-start同時更新をDevで確認し、初回並列deployでのquota失敗を低CPU構成で解消した。公開前の負荷/長時間音声検証は別途必要。

## Functionsの導入範囲

production.ts の別入口・codebase `aogaku-ai` から、次の**12個だけ**をdeployする。

```
aiCreateSource aiCompleteSource aiGetSource aiListSources aiGetEvidence
aiRetrySource aiUpdateSource aiDeleteSource aiRetrieveContext
aiProcessSource aiReconcileInputs aiRejectLateUpload
```

年度IDのDev版は13個。追加の `aiLinkSourceOffering` は保存・Dev検証済みだが、この初回本番allowlistに含めない。本番API/UIでは明示紐付けをOFFにする。localCourseUUID・年度別snapshot・本人の資料保存/検索は維持する。13個目の導入は別途承認とテストが必要。

旧askCourseAI、transcribeLectureAudio、generateReactionPaper、onAuthUserDelete、preDeleteCleanup、deleteAccountServerSide、import/reindex/wipe系、友人/通知3関数はこのpackageへ含めない。現在のSwiftソースには旧askCourseAI/transcribeLectureAudioへの直接呼出しを検出していない。稼働中関数の外部/旧クライアント呼出しはソース回収後に別途検証する。現在リポジトリにある友人3 handlerはmainとバイト一致を検査し、EmulatorではFCM transportだけを置換して通知/重複抑止/取消を回帰検証する。稼働ソースは後続作業で9関数分回収し、実コード付き回帰を完了。詳細はACCOUNT_DELETION_READINESS.mdを参照。

## 共有OFF・内部テスト限定・削除

- 本番共有はserverで必ずOFF。env flagを誤ってtrueにしてもverified membershipによる共有閲覧/共有変更を許可しない。本人の読み取り/検索/共有撤回は維持。UIはAPIのsharingEnabled/linkingEnabledに従う。
- `AI_INPUT_ALLOWED_UIDS` はJSON配列。初期本番は明示した内部テストUIDだけ。現在配列は空で、誰も新AI callableを利用できない。UIDリストはignored `Config/firebase-production.local.json` の `{"allowedUIDs":[...]}` に将来入力する。wildcard公開はwrapperで拒否。UIDはソースへcommitしない。
- 全callableでAuth UIDの存在/disabled状態とaiInputOwners tombstoneを確認する。アカウント削除開始後の新規受付・既存tokenの利用を拒否する。
- beginAIAccountDeletion(uid) は **Cloud Functionではない内部helper**。既存preDelete/deleteAccountServerSide/onAuthUserDeleteの適切な経路から呼び、Auth削除前にtombstoneを確定させる設計。
- 残るページはreconcileが25 sourceずつ再開。原本・派生物・runs/chunks・追跡済みTasks・aiUsage・本人のlocal offeringを削除し、内容のない最小source tombstoneとUID tombstoneを残す。遅延jobのpublishは禁止する。
- queue受付前にjob IDを記録し、enqueue/deleteの競合時も完了後の再読取りでtaskをcancelする。過去版の未追跡jobはIDがなく物理cancel不能だが、tombstoneで実行/publishを拒否する。初回本番には過去AI jobがない。
- Authだけ直接削除された場合も、APIは即拒否、reconcileがregistryを巡回して後処理する。これは**巡回による非同期fallback**で、全利用者が必ず15分以内に消える保証ではない。最大25 UID/回の巡回と10 deletion owner/回・25 source/pageで継続処理する。
- 元の稼働削除実ソースにhelperを接続したadapterと新クライアント接続は後続作業で実装/Dev検証済み。本番反映はまだ実施しておらず必須gateのまま。現在のGit mainクライアントは `Aogaku/AuthManager.swift` のdeleteAccountからuser documentを削除した後Auth.user.deleteを直接実行し（ProfileEditViewControllerから呼出し）、preDeleteCleanup/deleteAccountServerSideはSwiftから直接呼んでいない。新クライアントの削除開始接続と、Auth delete後の既存onAuthUserDelete hookの両方を確認する。削除成功後にはUID別の端末LocalSourceStore・会話・原本とin-memory storeも消去し、進行中uploadによる端末への再保存を拒否する接続が必要。helperを独立13/14個目の公開関数にすることで迂回しない。
- Storage soft-delete（現在7日）は保持されるため、通常の削除後に復元可能なオブジェクトversionが残る。現行ポリシーを変更せず、App Store公開前に利用者向け保持/削除方針を確認する。

## deploy wrapper / dry-run

```
python3 scripts/firebase_production.py check --project forta-aogaku
python3 scripts/firebase_production.py plan --project forta-aogaku
python3 scripts/firebase_production.py dry-run --project forta-aogaku
```

check/planはローカル、dry-runはmetadata読み取りのみ。`build/production-plan.json`、production-stack/endpoints.json、production-live.jsonを生成。firebase.json/dev設定/aliasから本番へ切り替えない。初回baseline＋追加deny以外のRules変更・既存index削除・fieldOverride変更・lifecycleの既存rule変更・対象identityの不一致・既存関数名との衝突は拒否する。SDK own index matcherでも既存定義との一致を確認する。

future deployは `--approval` の私有JSONが必要。target、phase、artifactSha256、直前5分内inventorySha256、1h未満expiresAt（Unix秒）、全requiredGates=true、delete/replaceExistingが空を検証する。現在approvalは作成していない。account削除hook・legacy回帰・内部テストUID・IAM/APIレビュー・明示本番deploy承認が未完了のためdeployを許可しない。

実行例は**将来の承認後だけ**：
```
python3 scripts/firebase_production.py deploy --project forta-aogaku --phase indexes --approval Config/production-deploy-approval.local.json
```

phasesはindexes/rules/functionsのみ。直接 `firebase --config firebase.production.json deploy` はpredeployで拒否。正規wrapperはsessionとartifact/hashを再検証し、明示 `functions:aogaku-ai:<name>` で12関数だけを指定する。

Firebase CLI 14.17.0に対してpreload guardをテスト済み。関数削除/危険な置換・Firestore index/fieldOverride削除とfieldOverride patchは常に拒否。AI finalizeのidempotent再試行だけを許可する。`--force`を使わない。SDK内部hookを使用するためCLI更新時は停止し、先にguardを再検証する。SDK/Toolsとデプロイ用Node22を固定した環境で本番作業する。

## 将来の反映順序（このターン未実施）

1. 既存削除/旧AIソースを回収し、削除開始helperを接続。Devで旧AI・録音・削除・友人通知の統合回帰を完了。verified membership未完成でも共有OFFは維持。
2. 本番metadataを再読取り。baseline drift、public IAM/ACL、CPU quota、課金/運用監視、Release bundle/entitlementsを確認。active Rules/fieldOverrides/indexes/lifecycle/IAM/既存関数inventoryをrollback用に退避。
3. 明示承認後、不足API/AI runtime SA/custom roles/必要な追加bindingだけ準備。既存GROQ secretへのAccessorのみ追加。queue/Run resourceは作成後にbindする。
4. index phaseでAI indexだけ追加、READY待機。既存3index/8override維持を再読取り確認。
5. rules phaseで統合Rulesを反映。lectureNotes/avatars/friends/検索を確認。既存権限の意味は変更しない。
6. 内部テストUIDだけを設定した12関数をwrapperで導入。Functions/runtime東京、Eventarc us-central1、bucket一致を確認。Tasks/Scheduler/service agent/AI3 Run Invokerを最小範囲で追加し、worker呼出し・イベント配送を確認。
7. lifecycleの追加は別レビュー。直前bucket metadataの**ifMetagenerationMatch**を使いlifecycleフィールドだけをmerge PATCHする。案ファイルでbucket全体をreplaceしない。既存users/ rule/soft-delete/ACLを再確認。[Storage precondition](https://docs.cloud.google.com/storage/docs/request-preconditions)。
8. 下記内部テストを通し、監視・課金・エラー率を確認。共有OFFのまま。main merge/App Store公開/一般ユーザーへのrolloutはそれぞれ別の明示承認まで停止。

## rollback手順（将来、別途承認が必要）

- 最初に新規AI受付を止め、内部UIDリストを空にする。必要に応じAI queueとAI schedulerだけ停止。既存Functions/他queueは触らない。
- AI関数は直前に退避した**同名12関数のAI codebase artifact**に戻す。旧13関数を含む全Functions deployや削除で戻さない。guard/CLI version/identity照合は維持。
- 追加denyは既存権限を変えないので原則残す。Rulesを戻す場合はlive driftを確認し、保存baseline以降の他チーム変更を保持する専用rollbackレビューを行う。通常wrapperは削除/変更を拒否するため、それを--forceで迂回しない。
- 追加AI indexは基本残す。既存index/overrideを削除しない。lifecycleを戻す場合も追加AI ruleだけを除き、現行ruleとの差分をreviewしてmetageneration前提でPATCH。
- AI資料/原本はrollbackで一括削除しない。tombstone/遅延upload cleanupと削除継続処理を維持。必要なruntime Secret/IAMを先に剥がして後処理を止めない。

## 本番内部テスト / 公開までの残条件

- 専用テストUIDの実授業 `YR:5桁ID`、semester、教員・授業名・URL snapshotを確認。実在他利用者の資料をfixtureに流用しない。
- 同じテストUIDで写真→OCR、PDF本文/OCR→page locator、メモ→文字位置、録音→ASR→時刻、本人一覧→根拠検索を確認。
- 別UIDはverified membershipを与えても共有/閲覧不可。共有OFF、raw private、直接Firestore/Storage access拒否、内部UID以外のAI callable拒否を確認。
- 重複request、通信中断/再送、upload/解析中削除、10分以内の遅延署名upload、Task重複、アカウント削除開始hook→Auth削除→原本/派生物/usage/jobsの消去→再生成なしを確認。
- bucketイベントregion、delivery SA、queue OIDC、scheduler invocation、API/Secret IAM、監視/エラーレート/費用を確認。
- 旧askCourseAI/文字起こし/アカウント削除/友人通知のsource付き統合回帰、実機長時間録音・着信・強制終了・圏外復旧、運用時の負荷/CPU quota、soft-delete/資料保持方針、共有verified membership生成経路は残条件。共有は経路完成後も別承認までOFF。
- 新しいAI資料を旧askCourseAIの回答へ自動追加していない。既存出力の挙動は維持し、出力側のaiRetrieveContext接続は別作業。
- 13個目link関数の本番導入、一般UIDへのrollout、main/PR merge、App Storeリリースはまだ承認していない。

## 検証結果

2026-10-06の最終確認結果。ローカルtest・Dev実通信のPASSは本番のIAM/API/イベント実配置成功を意味しない。production dry-runはplan/SDK manifest/metadata差分検査であり、実deployの代わりではない。

| 検証 | 結果 |
|---|---|
| iOS Debug build | BUILD SUCCEEDED |
| Simulator XCTest（Devのみ） | 2/2 PASS。年度snapshot/UUID、4入力実upload・保存・出典・ページ付き根拠検索 |
| TypeScript build / Functions domain単体 | build成功、13/13 PASS |
| 本番統合Rules/Storage/旧友人通知/削除/権限 Emulator | 18/18 PASS、skipなし、実クラウド接続なし |
| production safety / Firebase環境分離 Python | 11 + 9 = 20/20 PASS |
| Dev接続/CLI destructive prompt/production metadata Node guard | 5 + 3 + 2 = 10/10 PASS |
| Swift端末保存・年度snapshot検証 | PASS（復元・利用者分離・編集・削除・receipt維持・legacy復元） |
| Dev共有ON回帰 | 13/13 PASS。4入力、Vision/Groq実通信、共有/撤回、他授業拒否、重複、年度衝突、UUID/link、通信中断/再送、upload/解析中削除、遅延upload、Auth削除 |
| Dev共有OFF本番相当profile | 最終11/11 PASS。4入力と根拠、verifiedでも共有不可、lectureNotes/avatars回帰、index4件READY/override8件、通信中断/再送、upload/解析中削除、Auth削除・遅延upload |
| Production dry-run相当 | PASS。12 endpoint、東京runtime/US trigger、Release登録・project番号/bucket、active Rules・3既存index/8 override・lifecycle・13既存Function維持、Secret latest ENABLED、public IAM/default ACLなし。cloud mutation=0 |

途中経過を消さず保存した。Dev private profile初回の2件はsocket/HTTP応答喪失で失敗し、同じreceipt・同じ原本MD5を使う限定再試行で解消。最終11件は全成功。Simulatorでは署名bundleにFileProviderがFinder属性を付けたため生成物の出力先を/private/tmpへ移して解消。また保存済みDev資料が30件を超えたため、テストをnextCursorに対応させ、4資料すべての検索を改めて確認した。これらは処理結果のassertionを省略して成功扱いにしたものではない。

Devの最終状態はAI_SHARING_ENABLED=false、本番相当の統合Rules/profileを反映済み。GROQのpayloadは出力していない。以前のDev設定とE2E結果はprivate backupへ保存し、既存資料も保持した。

## 追加・変更ファイルと保存

このターンの主要変更（年度ID実装の未commit差分は別に維持）:

- Config/Production/*: 有効本番baseline、追加だけのRules/indexes/lifecycle案、identityとIAM案。
- firebase.production.json、functions/src/production.ts: 本番専用package/codebase、12関数入口、US Eventarc→東京runtime。
- scripts/firebase_production.py、firebase_prompt_guard.cjs、production_cloud.cjsと安全テスト3本: identity/drift/allowlist、削除・置換拒否、読み取り専用監査、reviewed artifact/approval gate。
- firebase.production-test.json、functions/test/production.test.cjs、legacy.test.cjs、emulator.test.cjs、functions/package.json: 統合Rules・旧通知・private/削除回帰。
- firebase.dev-production-profile.json、Config/Development/production-profile.storage.rules、scripts/firebase_dev.py、provision_dev.cjs、dev_e2e.cjs: Devだけのprivate profile、Auth get/Tasks cancel最小権限、E2E追加。
- functions/src/ai/index.ts: 共有OFF/pilot UID gate、Auth状態確認、削除helper/registry/Task追跡・取消、finalize再試行、軽い関数CPU調整。
- Aogaku/AIInput/SourceModels.swift、SourceLibraryViewController.swift、SourceIngestionService.swift: server flagに応じるUIとエラー表示。AogakuTests/AIInputDevIntegrationTests.swift: 同じreceiptで再送・複数ページ検索。
- .gitignore、docs/ai-input/API.md、本書: 私有設定/approval除外、仕様・手順・残条件。

Git branchはcodex/ai-input-main-integration、HEADはd3f56c6aeacb24f8c23a0c36c77d1feca29e230aのまま。staged差分なし、今回commit/pushなし。functions/node_modulesとfunctions/libの既存生成物差分はソースとは別扱いで、削除・commitしない。

ソースpatchと新規ソースarchiveを ../production-preparation-backup/ に保存した（Git対象外、private権限）。Dev plist/認証fixture/output-dev、build/production-*、実行log/xcresultもGit対象外で維持。production approvalは未作成。本番deploy・データ書込み/削除・IAM/API変更・Secret上書き/rotation、Aogaku-clean変更、GitHub/main/PR merge、アプリ公開はこのターン一切行っていない。

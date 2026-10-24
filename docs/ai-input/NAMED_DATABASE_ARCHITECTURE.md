# AI専用Firestore databaseへの分離

> 2026-10-07追記: このDev検証済み構成の本番Phase 2bは別承認後に完全成功。[本番実行結果](PHASE2B_NAMED_PRODUCTION_RESULT.md)を参照。以下は2026-10-06時点の設計・Dev検証記録で、当時の未実施条件を保存する。

2026-10-06。旧Phase 2bの「defaultへのAI deny追加」案を置き換える設計。本番の作成・反映・アクセスはこの検証では行わない。

## データ境界

| 保存先 | 内容 |
|---|---|
| `(default)` | 既存users/classes/friends/reviews/lectureNotes、旧privateUsage/quota。アカウント全体の再生成防止marker `accountDeletionFences/{uid}`のみ追加する設計 |
| `aogaku-ai`（東京・Native） | aiSources、aiCourseOfferings、aiUsage、aiInputOwners、aiMaintenanceと、そのjobs/runs/chunks/memberships/lectures/periods |
| 同projectのStorage | `ai-inputs/aogaku-ai/{uid}/{sourceId}/...`、`ai-derived/aogaku-ai/{uid}/{sourceId}/...`。client direct access deny、Callableが発行する限定署名URLでupload |

Admin SDKは `getFirestore(app, "aogaku-ai")` / `getFirestore(app, "(default)")` を明示。AI_FIRESTORE_DATABASE_IDはaogaku-ai以外なら受付拒否し、defaultへfallbackしない。通知・旧AI・旧削除もdefaultを明示する。回収した稼働版の原本は変更しない。

classesはdefaultからtransaction外で参照し、AI専用DBにsnapshotを保存する。`YR` → 時間割年度 → unresolvedの順、`{year}:{5桁classDocId}` と永続localCourseUUIDの仕様を維持する。翌年度のcatalog上書きで過年度資料は再解釈しない。

iOSはCallableだけを利用しFirestore pathに依存しない。旧Dev default AIデータ/原本は移行・削除せず保持。新しいfixture UID/stateを使用し、以前のDev端末cacheを新DBへ自動接続し直さない。XCTest fixture準備もnamed stateだけを使用する。

## Rules・indexes

`Config/AI/firestore.rules`は全面deny。defaultのproduction baseline Rulesをbyte単位で保持する。`/{path=**}/entries/{userId}` / collectionGroup("entries")はdefaultで従来どおり動作する。namedに同名の未登録pathをclientが選んでも拒否される。

namedにはaiSourcesのstatus ASC/updatedAt ASCのcomposite index 1件と、memberships.userIdのCOLLECTION_GROUP ASCのsingle-field設定1件。後者は通常のCOLLECTION ASC/DESC/ARRAY設定も保持する。defaultの既存index4件（Phase2a AI追加済みを含む）とfieldOverrides8件は反映対象外。

CLI14のFirestore array configでは `--only firestore:rules` だけではdatabaseが選択されない。必ず `firestore:aogaku-ai,firestore:rules` または `firestore:aogaku-ai,firestore:indexes` を併記し、実CLI parserの選択結果もテストする。本番configのFirestore配列にdefaultを入れることをguardで拒否する。

## 再試行・削除

受付/usage予約/実行lease/本文・chunks公開はnamed内だけのtransaction。旧quotaの予約・refund transactionはdefault quota + default accountDeletionFencesだけ。databaseを跨ぐtransactionは使わない。

削除開始はnamed ownerをdeletingにし、次にdefaultの共通fenceをdeletingにする。後者が失敗してもnamed markerで新AI・旧AIの入口を拒否する。cleanup再開時にdefault fenceを先に修復し、jobs/Tasks取消・原本/派生物・runs/chunks・usageを削除する。削除済みsource/ownerの最小tombstoneは残す。旧quotaは既存削除フローで消し、遅延refundはdefault fenceを同一DB transactionで検査して再生成しない。

資料のないmembership、親document欠損membershipもuserIdによるcollectionGroup検索で削除する。100件単位でdeleteし、残りはSchedulerで再開する。trusted membership作成者はuserIdを必須にし、ownerのdeletion markerを同じnamed transactionで確認すること。共有は引き続きOFF、verified membership生成経路は本番解放の別gate。

Task payloadにdatabaseIdを入れる。旧default/未指定/不一致payloadは新DBに触れる前にreturnする。Storage finalizeはnamed prefixだけを扱い、旧Dev unversioned原本やavatarsに触れない。遅延uploadはnamed tombstone・Auth状態で削除する。

## IAM

新APIは不要（既存Firestore API）。Devの既存runtime/deletion SAのdatastore.userで実通信を検証する。API key/SA keyは追加しない。VisionはADC、Groqは既存Secret Manager参照。

本番Phase1の既存bindingは変更しない。project-scope datastore.userはnamed DBにも適用されるため、単にdatabaseを増やしてもSAの権限が狭まるわけではない。将来最小化する場合はdatabase名に対するIAM Conditionsを使い、runtimeにはnamedの読み書きとdefault catalog/fence get/create/update、削除SAにはnamed + default cleanupを許可する。IAMでcollection単位の制限はできず、default fence権限は実装の固定path guardに依存する。既存bindingの撤去/追加は別承認で行う。

旧AI3の実行SAも新named ownerを参照できるか、承認後のfresh IAM確認が必要。queue/Secret/Vision/Eventarcの既存分離方針は維持し、secret payload/version・IAM・lifecycleはこの検証では変更しない。

## 本番Phase 2bの新しい順序（未実行）

1. 別承認を得てproject identity・default baseline・既存SAの権限を再照合し、aogaku-aiを東京Native・delete protection ONで作成。
2. named全面denyを維持し、named composite + membership field indexを追加、両方READYを確認。default AI indexを触らない。
3. named Rulesの稼働全文を照合し、Storageの既存baseline + AI denyだけを反映。
4. defaultのentries匿名read/query、lectureNotes/avatars/friends等の回帰と、named全領域のread/write拒否を確認。
5. named identity/index/field/Rulesを含むfresh metadataと新artifact hashで再承認。以前のPhase承認/検証receiptは流用しない。

本番wrapperはnamed databaseのfresh確認がない限りdeployを拒否する。Phase3の旧AI/削除wrapperもnamed Rules・indexesを含むfresh承認を要求する。失敗時は入力closed、queue/Scheduler PAUSEDを維持し、新DBを削除せずdefaultへのfallbackも行わない。必要なら承認済みStorage Rules releaseだけをdrift確認後に戻す。

Phase2bをこの構成で完了できる設計だが、本番named databaseは未作成・未検証なのでPhase2b完了/Phase3移行とは扱わない。

## 検証の再現

Emulator用CLI15.32.1/JAR1.22.0を使用。CLIは複数Rulesを自動ロードしないため、`scripts/run_named_emulator.cjs` が実Emulatorのdatabase別securityRules APIで各Rulesをロードし、named拒否/default公開をpreflight確認してから実テストを実行する。open Rulesの暗黙生成による偽陽性を防ぐ。実クラウドtransportはEmulatorテストで遮断する。

Devだけのprovision/deploy/checkは `provision_named_dev.cjs`、`provision_named_membership_index.cjs`、`firebase_named_dev.py`。旧default設定と過去AI資料/Storage generationのbefore/after証跡を保存する。最終結果は `build/named-firestore/` とNAMED_DATABASE_RESULTS.mdを参照。

公式資料：[複数database](https://firebase.google.com/docs/firestore/manage-databases)、[Emulatorのnamed databaseと制約](https://firebase.google.com/docs/emulator-suite/connect_firestore)、[IAM](https://firebase.google.com/docs/firestore/security/iam)。Emulatorはcompound indexを強制しないため、DevのREADYと実queryも必ず検証する。

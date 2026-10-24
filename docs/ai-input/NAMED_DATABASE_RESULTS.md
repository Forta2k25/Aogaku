# AI named database 検証結果

2026-10-06。Dev / Emulatorで完了。本番アクセス・変更、commit / push / mergeは実行していない。

## 最終構成

AI専用databaseは `aogaku-ai`（Native、asia-northeast1、delete protection ON）。aiSources / aiCourseOfferings / aiUsage / aiInputOwners / aiMaintenance、および jobs / runs / chunks / memberships / lectures / periodsを保存する。

`(default)` は既存users / classes / friends / reviews / lectureNotes / legacy quotaを保持。授業catalogを参照して年度snapshotをnamedへ保存する。アカウント全体の削除fence `accountDeletionFences/{uid}` は旧quota transactionとの連携に使うdefault側のmarkerで、AI本文・usageは置かない。iOSはCallable経由のみ。両databaseのAdmin SDK指定を明示し、暗黙default / 不一致IDへのfallbackを拒否する。

named Rulesは全面client read/write deny。必要indexは aiSources(status ASC, updatedAt ASC) composite 1件と、memberships.userIdのcollectionGroup single-field設定1件（通常の3設定を保持）。Devでは両方READYと実queryを確認した。defaultの4 composite / 8 fieldOverridesと既存entries条文は保持。

IAMは既存Dev SAで検証し、追加・削除・SA key作成・Secret変更はしていない。本番SAへのnamed/default権限照合と、必要ならdatabase IAM Conditionsによる最小化は別承認対象。詳細は [architecture](NAMED_DATABASE_ARCHITECTURE.md)。

## 検証結果

| 検証 | 最終結果 | ローカル証跡 |
|---|---|---|
| Simulator Debug build / Aogaku Scheme | PASS | build/named-xcode-debug.log |
| TypeScript / recovered Functions build | PASS | build配下のnamed buildログ、最終Dev deploy成功 |
| domain単体 | 13/13 PASS | build/named-unit.log |
| Emulator統合・既存Rules/旧Functions回帰 | 45/45 PASS、skip 0 | build/named-firestore/emulator-final.log |
| Python環境分離・production安全guard | 35/35 PASS | build/named-static-tests.log |
| Node CLI prompt / legacy / cloud guard | 7/7 PASS | build/named-node-guards.log |
| Dev Firebase実API E2E | 16/16 PASS | build/named-firestore/final-e2e-results.json |
| 旧Dev AI資料・原本/派生Storage generation保持 | PASS | build/named-firestore/preservation-post-check.log |
| default Rules / Storage Rules / indexes / fieldOverrides不変 | PASS | build/named-firestore/default-final-check.log |
| production config / allowlist offline check | PASS | scripts/firebase_production.py check（通信なし） |

Dev E2Eでは写真Vision OCR、PDF本文＋画像ページOCR、メモ、Groq ASR、17分音声の15分分割、page/文字位置/時刻、本人一覧・根拠検索を確認。さらに再送・重複receipt・通信中断、upload中/解析中削除、遅延upload、年度URL優先・同じ5桁ID再利用・frozen snapshot・UUID・unresolved・canonical link、共有OFF・他人拒否を確認した。

削除は preDeleteCleanup→Auth削除 / deleteAccountServerSide / onAuthUserDeleteの3経路。受付停止、named/default fence、Tasks取消、原本/派生物・jobs/runs/chunks/usage・旧quota削除、親欠損membership cleanup、遅延worker拒否、遅延upload除去をDevで確認。Emulatorでは100件超membership再開、fence間の失敗復旧、quotaの遅延reserve/refundによる再生成防止も確認した。databaseを跨ぐtransactionは使わない。

旧AI3・旧文字起こし・友人通知は回収実ソースのEmulator/provider mock回帰で検証。旧AI3・友人通知の実クラウドdeployは行っていない。端末保存・会話/添付state削除の既存実装を保持し、今回のDevサーバー削除E2Eを新しい実機操作検証とは扱わない。

初期fixtureの共有OFF時の期待error、fresh stateのRules probe参照を修正済み。途中のharness失敗履歴は削除せず保持。iCloudのdataless source/JDK問題はファイル復元と/tmpの検証済みJDKで解消し、最終build/Emulatorを再確認した。

## 変更した主な実装

- functions/src/ai/databases.ts（新規）：明示database、共通削除fence、Storage namespace。
- functions/src/ai/index.ts：catalog default / 保存named、Task databaseId、namespace付きfinalize、冪等cleanup、orphan membership sweep。
- functions/src/legacy-ai/index.ts、legacy-account/index.js、index.ts：default明示、旧quota同一DB fence、既存削除helper接続維持。回収原本は不変。
- Config/AI/firestore.rules / firestore.indexes.json（新規）、firebase.named-dev.json：namedだけを選択するdeny / index構成。
- Config/Production/target.json / named-firestore.plan.json / rollout.phases.json、firebase.production.json、firebase_production.py / firebase_legacy_production.py / production_cloud.cjs：named identity/index/RulesとCLI database selectorの安全guard。default Rulesはbaseline同一へ戻し、以前のdefault deny案を廃止。
- Dev provisioning / preservation / Rules / Functions検証スクリプト、run_named_emulator.cjs、dev_e2e.cjs、Functions/Python回帰：専用fixture・強制Rulesロード・旧default保持の検証。
- prepare_account_deletion.py / prepare_legacy_production.py / prepare_dev_ios_e2e.py：明示database設定・新fixture namespace。
- architecture / rollout / Rules監査関連docs：新構成へ更新。

既存未commit作業と生成物は保持。functions/node_modules / functions/lib / build / private config / E2E認証stateをソース変更と分離し、Gitには追加していない。

## 本番の状態と次の条件

Phase 2bはこの構成で完了可能な設計だが、本番named databaseは未作成・未検証。**Phase 2b本番完了ではなく、Phase 3へは進めない。**

別承認後に本番identity/default baseline/SAを再照合し、named DB作成→named全面deny→named index/field READY→Storage既存baseline＋AI deny→既存entries query/権限回帰→新metadata/artifactの承認が必要。旧承認receiptは流用できず、wrapperがfail closedする。既存本番defaultのPhase2a AI indexは一切触れていない。

本番アクセス0、変更0。Devの既存データは移行・削除していない。新fixture専用DB/Storage prefixを使用。共有OFF。Dev queue/SchedulerはE2E用に再開済み。本番queue/Schedulerには触れていない。

## 保存

branch: codex/ai-input-main-integration、HEAD: d3f56c6aeacb24f8c23a0c36c77d1feca29e230a。staged 0。main基点・保存AI commitは変更していない。

現在ソースpatch・untracked source・private E2E証跡を、repo外の `../named-database-backup-20261006-225824` に保存。以前のbackup/検証結果も保持。生成物や認証stateはソースpatchへ含めず、証跡はprivateディレクトリに分離する。

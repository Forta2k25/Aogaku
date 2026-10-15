# Phase 5a: PARTIAL / SAFE STOP

> これは前回停止時の履歴です。今回の再開は完了し、最新結果は [PHASE5A_COMPLETE_RESULT.md](PHASE5A_COMPLETE_RESULT.md) に記録しています。

確認日: 2026-10-07。対象: `forta-aogaku` / `505828754933`。
Phase 5bは未実施。GitHub push、merge、App Store公開、Aogaku-clean変更なし。

## 実行した本番変更

1. 別途承認された非許可UIDの使い捨てAuth accountを1件作成。許可リストに追加せず、AI資料やStorage fixtureは作成していない。
2. `aiCreateSource`の`serviceConfig.environmentVariables`だけをPATCH。`AI_INPUT_ALLOWED_UIDS`を指定内部UID 1件にした。他の環境変数はbaselineと同一。UIDと本人/使い捨てtokenはGit除外のprivate local configだけに保存。

残り9 FunctionsのUID設定、9 Callableのpublic invoker、queue resumeは未実施。
現在は9 CallableすべてIAM privateで、指定UIDも通常のFirebase Callableから利用できない。
`aiCreateSource`以外のAI11 FunctionsはallowedUIDs空。sharingは全12件OFF。

## 停止理由と確認結果

環境変数だけのPATCHでもCloud Functionsはnative rebuildを実行し、build IDとsource ZIPのgenerationを更新した。operationは成功し`aiCreateSource`はACTIVEだが、旧ガードのbuildConfig完全一致条件により停止した。

- 25/25 FunctionsをSourceCodeGetで再取得し、全ファイルのmanifestが変更前と一致。新AI12件のSHAはすべて`34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8`。package-lock.jsonも同一。
- `aiCreateSource`はNode22 / Tokyo / runtime SA / trigger / IAM / named DB維持。指定UID設定以外の環境変数はbaseline hashと一致。
- 他24 Functionsのmetadata/updateTime/sourceは不変。既存13 Functionsも不変。
- named/default DB、Rules/indexes、project/resource IAM、Secret metadata/version、Storage lifecycle、Eventarcは不変。
- queue `aiProcessSource`はPAUSED。SchedulerもPAUSED、lastAttemptTimeなし。
- 全9 CallableのRun URLとcloudfunctions.net URLへのanonymous GET、18/18件が403。public invoker追加なし。
- Phase 5aのbaseline作成以降、read-only transient retryの発生は0件。mutation自動retryは0件。

停止journal・元baseline・元approvalは保持。本番の続行は行っていない。

## ローカル修正・検証

修正版revision guardは、稼働source全文が承認済みmanifestと一致する場合に限り、native rebuildのbuild参照と同じbucket/objectのgeneration更新を許容する。
runtime、SA、region、source bucket/object、provenance、trigger、その他設定の変更は拒否する。各revision後にSourceCodeGetを必須化し、以後のprotected auditもそのrevisionのbuildConfig hashを固定して確認する。

ガード/read-only retryテスト: **14 PASS / 0 FAIL**。
今回の実稼働metadataとinstalled manifestを使った修正版guardのローカル検証もPASS。
証跡保存のnested directory作成、および既存redactionとのmetadata hash方式の統一も修正した。元approval/journalのhashとsource ID計算は維持。

## E2E状態

| 確認項目 | 結果 |
| --- | --- |
| fresh production preflight / 25 manifests | PASS |
| 本人ログインproject/UID照合 | PASS |
| 使い捨て非許可UID作成 | PASS、非許可のまま |
| 9 Callable × anonymous/非許可/内部UID app gate | 未実施（IAM privateのanonymous GETは18/18拒否） |
| メモ / 写真Vision OCR / PDF抽出・OCR / 録音Groq ASR | 未実施 |
| evidence / retrieve context / list | 未実施 |
| 実処理によるnamed/default DB境界 | 未実施、metadata境界は維持 |
| direct Firestore/Storage拒否E2E | 未実施、Rulesは不変 |
| duplicate / upload中断→再送 | 未実施 |

ローカルsynthetic assets: `sample-photo.jpg`、本文＋画像の2ページ`sample-document.pdf`、12.466秒のTTS`sample-audio.m4a`、架空メモ。
production AI DB/Storageへの入力fixtureは0件。
使い捨て非許可Auth accountはprivate registryで追跡し、再開後の拒否確認を終えてから、承認済みのcleanupで削除する。本物の内部UIDは削除しない。

## 再開時の手順

「各Phaseでpartial successや想定外driftが発生した場合は停止」という指定に従い、今回の本番変更はここで停止。
修正版guardで残作業を再開する承認後に、現在の本番状態をfreshに照合し、新artifact/receiptを作成する。
すでに設定済みの`aiCreateSource`を再PATCHせず、installed manifestの検証結果を引き継ぐ。
残り9件のUID設定 → 9 Callableだけpublic HTTP invoker → 27 Auth gate checks → queueのみresume → 4入力 → duplicate/再送 → direct-access拒否 → 使い捨てAuth cleanup → 最終audit、の順に進める。

SchedulerはPAUSED、sharing OFF、background 3件privateを維持。
Phase 5bの削除競合・遅延worker・遅延upload finalize・Scheduler実行・長時間録音・provider障害・quota限界・共有/一般開放は引き続き対象外。

証跡: Git除外`build/production-phase5a/`内の`execution.json`、`baseline.json`、`stopped/result.json`、`stopped/environment-only-proof.json`、`stopped/revised-guard-proof.json`。Auth/UIDファイルは公開しない。

## 追加・変更したソースファイル

- `scripts/phase5a_login.py`: 本人のEmail/Password非表示入力とprivate token保存。
- `scripts/production_phase5a_preflight.cjs`: Phase 4完了状態に対するread-only preflight。
- `scripts/production_phase5a_common.cjs`: 対象照合、private config、masked証跡、read-only snapshot。
- `scripts/deploy_production_phase5a.cjs`: env-only PATCH / 9 Run resource IAM / queue resumeの限定wrapper。
- `scripts/production_phase5a_revision_guard.cjs`: full-source一致必須のnative rebuild guard。
- `scripts/production_phase5a_auth.cjs`: 承認済みの非許可Auth accountの作成/cleanup。
- `scripts/production_phase5a_e2e.cjs`: synthetic 4入力、duplicate/中断再送、直接アクセス拒否harness。
- `scripts/audit_production_phase5a.cjs`: 完了時の全25 source/protected-state audit（未実行）。
- `scripts/audit_production_phase5a_stop.cjs`: 停止後のread-only全25 source/protected-state audit。
- `scripts/test_production_phase5a.cjs`、`scripts/test_production_phase5a_revision.cjs`: mutation範囲・revision guardの回帰。
- 本報告書。

アプリ/Functionsの実装source変更・source deployは今回0件。

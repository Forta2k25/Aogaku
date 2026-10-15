# Phase 3a 本番反映結果（2026-10-07 JST）

**完全成功。Phase 3bは未実行で、追加承認待ち。**

対象は `forta-aogaku` / `505828754933` / `forta-aogaku.firebasestorage.app` / Release bundle `com.forta2k25.Aogaku`。毎回最新metadataを照合した。App Store公開版には旧AIの利用導線がない。今回もアプリ公開・一般向け新AI解放は行っていない。

## 実施した3件

| Function | versionId | runtime / region / trigger | memory / timeout |
| --- | --- | --- | --- |
| askCourseAI | 3 → 4 | Gen 1 / Node.js 22 / asia-northeast1 / Callable HTTPS | 256 MB / 120秒、不変 |
| transcribeLectureAudio | 4 → 5 | 同上 | 512 MB / 540秒、不変 |
| generateReactionPaper | 4 → 5 | 同上 | 256 MB / 120秒、不変 |

旧AI3件だけをexportする5ファイルのartifactを作成し、元の依存lockをそのまま使用。旧provider処理・入出力・model・quota契約を保持した。新AIのOCR/Tasks/保存worker・アカウント削除handlerはartifactに含めていない。

コード差分は明示的な `(default)` 利用と、Auth状態・default deletion fence・named owner tombstoneの確認、reserve/refund transactionでの削除後再生成防止。Auth不存在時はdefault fenceだけを保存し、named DBへの新AI保存処理は追加しない。

1件ずつ、最新metadata/SourceCodeGet → signed source staging upload → **`updateMask=sourceUploadUrl`だけのGen 1 PATCH** → operation完了 → 稼働ソース全ファイルSHA一致 → 全保護対象post-checkの順に実行した。Firebase CLI deployは使わず、API/IAM/Secret binding等の自動変更を避けた。全Functions deploy・削除・force・自動rollbackはない。

## before / after source SHA

Source SHAは、ZIP内の全ファイル名と各SHA-256をソートしたJSON manifestのSHA-256。ZIPの包装ではなく、完全な稼働ソースの内容を照合している。3件とも同じ値。

| 種別 | before | after |
| --- | --- | --- |
| 完全source manifest | `8d6e7341bc9a2077f5b8b8835b99ef4f16e01ec40ad318cada38b52b0b2a3eef` | `ca3d2a13858f7c498b5edf4f385386e3273dfc1dbdbca168f97443cb0211e8b8` |
| ZIP bytes | `c294d2544b718c0592e4fdc6b2c9d5a3984d8c10862ca53212164044f0b8cdc2` | `839f2d3fc8bf03595790bb378779f73f2874d4280295d4b18cd52f69a96ecf1c` |
| `lib/index.js` | `12ed370d671b67d829c282497f0f46152a2e6590acb306a2695a4afecbf61ee6` | `8cad80d016223985f76e80cb5edc6b0f2d4b7da2b16017b17dd839847910ad46` |

afterのentryは3件をexportするloader。本体 `lib/legacy-ai/index.js` のSHAは `90596de65df1e4bd4331b8b328db5c30da89aca44c7c5f63a5d8191707c87ff9`。関数labelの過去hashを証拠として流用せず、毎回SourceCodeGetの実ZIPを照合した。

最終updateTime（UTC）: ask `2026-10-06T15:47:25.488Z`、ASR `2026-10-06T15:52:48.020Z`、reaction paper `2026-10-06T15:55:13.920Z`。

## 検証結果

- TypeScript build / recovered build: PASS。
- 反映前Emulator + provider mock: **48 PASS / 0 FAIL / 0 SKIP**。
- 反映後同回帰: **48 PASS / 0 FAIL / 0 SKIP**。
- 対象/禁止操作/未発行URL/別project/DB差分/Gen 1 staging照合ガード: **6 PASS**。
- 個別post-check、最終3件SourceCodeGet、既存installed gate用verifier: 全PASS。
- 旧回答・ASR・リアクションペーパーの入出力、model、provider失敗時のquota返金、quota消費、削除fence・遅延reserve/refund再生成防止、友人通知、既存/AI Rulesを再検証。
- 削除3handlerとの接続回帰はEmulator上で検証した。**本番の削除3handlerは今回変更していない。**

実providerの本番呼出し、本番ユーザーデータを用いたquota消費や削除テストは行っていない。契約回帰は実ローカルDB/Storageとprovider/Auth mockで検証した。

## 保持したもの

- Functions全13件のinventoryを保持。対象外10件は全文metadata/updateTime不変。
- runtime SAは既存App Engine default SAのまま。対象3件のtrigger、設定、IAMも不変。
- OPENAI/GROQ参照はversion **1固定**。Secret metadata/version一覧/IAM不変、payload取得・表示・rotationなし。
- project/bucket/Secret/runtime self/queue/対象FunctionsのIAM不変。専用SAのuser-managed keyは0件。
- default DB Rules、composite **4件**、fieldOverrides **8件**不変。
- named `aogaku-ai` のuid/region/Native/delete protection/設定、deny Rules、必要index不変。
- Storage Rules、bucket lifecycle、soft-delete、queue **PAUSED**、Scheduler、Eventarc、API一覧不変。
- 本番Firestore/Auth/Storageのユーザーデータ書込み・削除なし。転送したものはGoogle管理のFunction source artifactだけ。

## 途中の停止と修正

1. 初回preflightでnamed DBのetagだけが旧snapshotと異なり停止した。連続した読み取りでもetagだけが変化し、全resource fieldとupdateTimeは不変と確認。etagのraw値は証跡に保持し、その他すべてのDB fieldを厳密比較するガードへ修正した。DBを更新する手順ではないため、etagはupdate/deleteの代用には使っていない。[Database公式仕様](https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases)
2. 最初のstaging URL発行後、Gen 1のbucket命名を誤って想定したガードで停止した。この時点ではsource PUT/PATCHは0件。既存3件のmetadataにある同じGoogle管理`uploads-…asia-northeast1.cloudfunctions.appspot.com` bucketへ、発行URLを完全照合するよう修正し、新しいpreflight/approvalで実行した。
3. 追加したASR拒否テストは必要な音声fixture欠損で1件失敗したため、Emulator fixtureを補って再実行した。API契約/実装変更は不要だった。
4. 作業フォルダの監査JSONがiCloudでdataless化してローカル読み取りが滞った。指定ファイルだけをdownloadして復元した。本番PATCHの再送は行っていない。

上記停止ログは残している。実際の本番Function更新3件のerror/partial successは **0**、予期しない設定driftも0。停止時にforce・削除・全Functions deploy・他設定変更は行っていない。

## 証跡・次の条件

Git除外の `build/production-phase3a/` に最新approval/artifact manifest、before/after metadata、原ソースZIP、各operation、各installed ZIP、最終結果を保存。停止時証跡は `preflight-etag-false-positive/` と `prepatch-staging-guard-stop/` に分離した。`build/legacy-production-installation.json` のquota groupだけを実ソース一致確認後に記録し、deletion groupは更新していない。

Phase 3aの完了条件は満たした。Phase 3bは**新たな承認、削除3件の最新artifact/metadata、使い捨て内部UIDでの本番削除E2E**が必要。Phase 4以降、新AI公開、共有ON、queue再開は未実行。Git commit/push、main/PR merge、App Store公開、Aogaku-clean変更も行っていない。

## 今回のソース変更

- `functions/src/legacy-ai/account-state.ts`: 旧AI専用の小さなAuth/fence guard。新AI workerをimportしない。
- `functions/src/legacy-ai/index.ts`: 上記guard/default DB参照へ接続。
- `functions/test/rollout-artifacts.test.cjs`: slim artifactの契約・全3件fence拒否・Auth欠損時の非再生成を追加。
- `scripts/prepare_phase3a.py`: 新鮮な実稼働ソース/依存lockから3件専用artifactを作成。
- `scripts/deploy_production_phase3a.cjs`: exact target、source-only PATCH、個別post-check、停止journal。
- `scripts/test_production_phase3a.cjs`: 上記ガード6件。
- `scripts/verify_legacy_install.cjs`: installed quotaのslim artifactを正しく検証し、6-handler packageの不要な再deployを要求しない。
- 本書、README、最終rolloutの最新状態注記。生成物・approval・生metadata・ZIPはソースと分離。

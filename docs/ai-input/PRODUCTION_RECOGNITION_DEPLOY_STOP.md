# 本番recognition移行: SAFE STOP（2026-10-08）

**移行未完了。Functions更新 0/10。queueはPAUSED。**

本番Project `forta-aogaku` / Number `505828754933` / bucket / Release Bundle ID / named DBをfresh照合。25 Functions metadata・IAM・installed full sourceを取得し、最新artifactと結び付けた承認記録をGit除外private directoryへ保存。現行pilot 2件が対象10 Functionsで完全一致、sharing OFF、Scheduler PAUSED。source-only更新候補は前レビューと同じmanifest（2061dbc03d0a6470879d185ee5ed85cd220bca5040d976a71717db1228ff1d56）。UID値は本document/sourceへ含めない。

## 停止理由

本番mutationは `aiProcessSource` queueのPAUSE 1件だけ成功（HTTP 200）。その直後、実行中dispatch確認に `GET /v2/.../queues/aiProcessSource?readMask=name,state,stats` を使ったためHTTP 400。実行スクリプト側のAPI version指定ミスで、Function staging/PATCHに到達していない。

[Cloud Tasks v2 get](https://docs.cloud.google.com/tasks/docs/reference/rest/v2/projects.locations.queues/get) はreadMaskを持たず、[v2beta3 get](https://docs.cloud.google.com/tasks/docs/reference/rest/v2beta3/projects.locations.queues/get) でstatsを明示取得する仕様。local guardを修正し、正しいGETの実通信成功・PAUSED・concurrentDispatchesCount=0（proto JSONのzero省略）を確認。書込みの再試行・自動復旧は行っていない。

ユーザーの「途中で失敗したら停止し、勝手に追加変更しない」条件に従い、修正後もdeploy/queue resumeを実行しない。

## 停止後audit

- 全25 Functions metadata/updateTime/runtime/source参照/IAMがfresh beforeと完全一致。更新revisionなし。
- named/default DB、Rules、indexes、project/resource IAM、Secret metadata/version、Storage lifecycle、Eventarc、SA keys不変。
- pilot 2件保持、sharing OFF、Scheduler PAUSED、Callable HTTP IAM不変、worker private。
- queueのみRUNNINGからPAUSED。rate/retry等の設定不変。復旧は未実施のためpilotのAI worker処理は停止中。
- 旧Phase5a synthetic OCR資料の本人Callable閲覧PASS。既存資料の再処理・削除なし。
- 新画像2枚・2ページPDF・短い合成音声・メモのfixtureはローカル準備のみ。本番新source/Storage object作成なし。
- 本番Qwen/Turbo新E2E、usage/cost、検出結果UI、非pilot拒否/direct拒否の再検証は未実施。
- Firebase Auth新規ユーザーは未作成。非pilot拒否用disposable 1件の作成/確認後削除は追加承認待ち。
- ローカル回帰54/54 PASS、candidate/new scriptsのprivate UID/server secret scan 0 matches、git diff --check PASS。

## 更新対象とrevision（before = 現在）

| Function | revision | after |
|---|---|---|
| aiCreateSource | aicreatesource-00003-jid | 不変 / 更新未実施 |
| aiCompleteSource | aicompletesource-00003-sen | 不変 / 更新未実施 |
| aiGetSource | aigetsource-00003-giq | 不変 / 更新未実施 |
| aiListSources | ailistsources-00003-xeq | 不変 / 更新未実施 |
| aiGetEvidence | aigetevidence-00003-xus | 不変 / 更新未実施 |
| aiRetrySource | airetrysource-00003-duj | 不変 / 更新未実施 |
| aiUpdateSource | aiupdatesource-00003-law | 不変 / 更新未実施 |
| aiDeleteSource | aideletesource-00003-ciw | 不変 / 更新未実施 |
| aiRetrieveContext | airetrievecontext-00003-vut | 不変 / 更新未実施 |
| aiProcessSource | aiprocesssource-00003-mep | 不変 / 更新未実施 |

## 次の再開

追加承認後、STOPPED journalやupload URLを再利用せず、現在PAUSEDを前提とするfresh resume baseline/approvalを作る。queueを再PAUSEしない。修正済みGETでdrain/leasesを照合後、レビューの順序で10件source-only PATCH、full installed source/protected post-check、Auth gatesを確認し、承認済みの元RUNNINGへresumeする。SchedulerはPAUSEDのまま。既存pilotだけsynthetic E2Eを行う。失敗時の再試行/自動rollbackなし。

Functions rollback対象なし。ただしqueueのRUNNING復旧が未完了なので成功とは判定しない。Git commit/push/merge・App Store公開・Aogaku-clean変更なし。

追加local source: scripts/deploy_production_recognition.cjs、scripts/production_recognition_e2e.cjs、scripts/test_production_recognition_deploy.cjs、本document。
private evidence: build/production-recognition-deploy-20261008/（Git除外）。最初の認証ファイル所在確認停止（mutation 0）のbaselineは sibling -preflight-initial へ保存した。元作業コピーの認証file/evidenceは保持し、現行allowlistに含まれるpilotであることを照合して認証を更新した。token/UID/Secret payload/signed URLは出力しない。

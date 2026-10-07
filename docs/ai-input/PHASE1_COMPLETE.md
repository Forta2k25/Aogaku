# Phase 1 最終結果（2026-10-06）

**Phase 1完全成功。Phase 2へ進める状態だが、追加承認待ちで停止。**

対象: `forta-aogaku` / `505828754933` / `forta-aogaku.firebasestorage.app` / `com.forta2k25.Aogaku`。実行前・各mutation前・post-checkで照合。

## 保持したもの

API3、SA2、custom role6はGETで再照合し、再作成・更新していない。Tasks/Schedulerの既存自動serviceAgent bindingを維持し、再生成していない。初回Phase 1以前からのIAM bindingも全件保持。

## 今回追加したもの

- 不足していたEventarc/PubSubのmanaged identityを正確なproject numberのService Usageで確認・準備。返却emailを照合し、それぞれのserviceAgent roleのみ。
- Storage service agentへPub/Sub publisher。
- 下記runtime SAの計画済み不足bindingのみ、現行etag/versionを保持して加算。
- 不存在を2回確認したTokyo queueを作成→直後に明示pause→GET PAUSED。その後queue単体IAM追加。

## runtimeごとの最終IAM（Phase 1）

| SA | scope | roles |
| --- | --- | --- |
| aogaku-ai-runtime | project | `projects/forta-aogaku/roles/aogakuAIAuthRead`, `roles/datastore.user`, `roles/eventarc.eventReceiver`, `roles/serviceusage.serviceUsageConsumer` |
| aogaku-ai-runtime | bucket | `projects/forta-aogaku/roles/aogakuAIStorageIO` |
| aogaku-ai-runtime | secret | `roles/secretmanager.secretAccessor` |
| aogaku-ai-runtime | self | `projects/forta-aogaku/roles/aogakuAISignBlob`, `roles/iam.serviceAccountUser` |
| aogaku-ai-runtime | queue | `roles/cloudtasks.enqueuer`, `roles/cloudtasks.taskDeleter` |
| aogaku-ai-account-deletion | project | `projects/forta-aogaku/roles/aogakuAccountAuthCleanup`, `roles/datastore.user`, `roles/serviceusage.serviceUsageConsumer` |
| aogaku-ai-account-deletion | bucket | `projects/forta-aogaku/roles/aogakuAccountStorageCleanup` |
| aogaku-ai-account-deletion | queue | `roles/cloudtasks.taskDeleter` |

AI Storage custom role: objects get/list/create/delete。削除SA Storage custom role: objects get/list/delete。AI Authはusers.getのみ、削除SA Authはusers.get/delete。signBlobはAI SA自身だけ。Storage scopeは本番bucket単体（AI prefix条件をIAMへ追加したとは扱わない）。

Secret Accessorは既存GROQ_API_KEYのresource policyだけ。project全体へSecret Accessorを付けていない。削除SAにSecret権限なし。version1 ENABLEDと完全なversion metadata一覧が前後一致。payload取得・表示なし。

## queue

`projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource`

- PAUSED
- maxConcurrentDispatches: 3
- maxDispatchesPerSecond: 500
- maxBurstSize: 100（Google計算値）
- maxAttempts: 4
- minBackoff: 30s / maxBackoff: 300s / maxDoublings: 16
- AI runtime: enqueuer + taskDeleter / 削除runtime: taskDeleter

## post-check

- 作成済みSA metadata/uniqueId、role metadata/etag/権限が実行前後で一致。
- 両SAのUSER_MANAGED key一覧は0件。key作成APIは実行ガードで拒否。
- 初回Phase 1前・今回開始前の既存IAM binding保持。conditional bindingも維持。
- Rules/indexes/fieldOverrides/Functions一覧とupdateTime/lifecycle/soft-delete不変。
- 本再開は9 mutationすべてCONFIRMED、errorなし、partial successなし。前回停止状態は解消。
- 安全テスト8/8成功。クラウドFunctions/Rules/indexesはdeployしていない。
- Auth/Firestore/Storageユーザーデータは読み書きせず、Secret値・versionは変更なし。
- GitHub push、main/PR merge、App Store公開、Aogaku-clean変更、一般AI解放、共有ONなし。

## Phase 2の境界

Phase 1のpost-checkはすべて合格。Phase 2を実行するための追加承認は受け取っていないため停止。AI worker metadata GETとCloud Run invokerのresource bindingは、対象Functions/Runサービスを作成するPhase 4で正しい実名を確認して追加する。これらを先行してproject全体へ付与していない。

私有証跡: build/production-phase1-resume/{execution,before,after,resources-before,final-result,policy-*-after,authorization.private}.json。初回partial evidenceも保持。

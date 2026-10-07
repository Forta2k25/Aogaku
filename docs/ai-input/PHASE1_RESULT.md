# Phase 1 本番反映結果（2026-10-06）

> この記録は初回partial successの履歴。追加承認後に残作業が完了した最新結果は [PHASE1_COMPLETE.md](PHASE1_COMPLETE.md)。

**PARTIAL SUCCESS / 停止済み。Phase 2へは進めない。**

対象4識別値: forta-aogaku / 505828754933 / forta-aogaku.firebasestorage.app / com.forta2k25.Aogaku。再照合一致。

## 反映・確認済み

- Cloud Tasks / Cloud Scheduler / Vision APIを有効化。
- aogaku-ai-runtime / aogaku-ai-account-deletion SAを作成（有効、鍵作成なし）。
- custom role6件を作成。権限は計画と完全一致。
- GoogleがTasks/SchedulerのserviceAgent roleを該当managed agentへ自動追加。既存IAM削除なし。

## 停止点と修正

Cloud Tasks generateServiceIdentityは受理されたが、Google-managed agentを通常SAと同じcustomer-project IAM GETで照合しようとして404となった。projects/-での読み取りも403で、通常SAのGETをmanaged identityの存在判定に使う確認方法が不適切だった。API/GCPの障害とは断定しない。

ローカルの確認ロジックは、project IAMの正確なserviceAgent role/member照合、不足時のproject-number限定Service Usage生成応答email照合へ修正した。6件のローカル安全テスト成功。**修正後のクラウド書き込み・再実行は行っていない。**

## 未実施

- AI runtime / deletion runtimeへ計画済み最小IAM binding追加。
- GROQ_API_KEYへのSecret Accessor追加。
- self actAs/signBlob、Storage、queue等のbinding追加。
- Tokyo aiProcessSource queue作成とPAUSED化。現時点でqueueは未作成。
- Phase 2以降。

## post-check

- Secret version一覧・状態不変。payload取得・表示なし。
- 既存Functionsの一覧・updateTime不変。
- Firestore/Storage Rules、indexes、fieldOverrides、lifecycle、soft-delete不変。
- 既存project/bucket/Secret IAM binding保持。
- Firestoreユーザーデータ、Auth、Storage objectは読み書きしていない。
- GitHub push/main・PR merge/App Store公開/Aogaku-clean変更なし。

## 再開条件

Phase 1残作業について利用者の再承認が必要。作成済みAPI/SA/rolesを新規作成し直さず、最新metadataと権限を再照合して不足bindingだけ加算する。queue不存在を再確認して作成→即pause→GET PAUSED。partial success時は再び停止。

自動rollbackは実施しない。API/専用SA/custom rolesを現状維持し、Secret・既存権限を変更しない。

私有証跡: build/production-phase1/{execution,audit-execution,before,after,protected-config-postcheck,resume-plan.private}.json。旧AI3の公開アプリに利用導線なしという前提を最終手順へ反映。削除3は既存ユーザー影響ありのまま。

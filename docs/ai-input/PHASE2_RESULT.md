> 2026-10-06: Phase2bはnamed database分離案へ変更。最新構成は [NAMED_DATABASE_ARCHITECTURE.md](NAMED_DATABASE_ARCHITECTURE.md) を参照。本書のdefaultへのAI Rules追加案・過去receiptは本番反映に使用しない。

# Phase 2 結果 — 2a完了、2bは反映前に停止

> 2026-10-07追記: named database構成のPhase 2bは別承認後に完全成功。[最新本番結果](PHASE2B_NAMED_PRODUCTION_RESULT.md)を優先する。以下の停止・BLOCKED記載は旧構成での履歴で、変更せず保存する。

検証日: 2026-10-06。Phase 2だけの承認に基づく実行。Phase 3以降の承認・実行はない。

後続の[schema監査とDev再検証](SCHEMA_COLLISION_AUDIT.md)で、実装には元からAI用`entries`がないことと、clientがschema外のpathを作成できることを確認した。既存entriesの除外条件案はユーザー指示で不採用。Phase 2bは引き続きBLOCKED。本書の「次の判断」は初回停止時点の履歴であり、後続の監査結果を優先する。

## 本番に反映したもの

- Project ID `forta-aogaku` / Project Number `505828754933` / bucket `forta-aogaku.firebasestorage.app` / Release Bundle ID `com.forta2k25.Aogaku` を最新metadataとローカルRelease設定で再照合した。
- `aiSources` のcomposite index 1件のみ追加した。`queryScope: COLLECTION`、`status ASCENDING, updatedAt ASCENDING`。
- index: `projects/forta-aogaku/databases/(default)/collectionGroups/aiSources/indexes/CICAgNjpgYIK`。
- 2026-10-06 12:09:21 UTCのpost-checkで全4件がREADY。元の3件はresource ID・定義・状態を含め不変。
- fieldOverrides 8件は全文不変。API応答には既定の継承設定1件も含まれるが、これはfieldOverrideに数えない。
- index-only REST wrapperの変更操作は当該indexへのPOST 1回だけ。削除・更新・Rules release・IAM変更等は許可しない。Firebase CLIによる付随的なAPI/IAM変更を避けるため、承認済み定義・既存production guardを照合して限定したAPIを使用した。
- Phase 2aのAPIエラー・partial success・driftはなし。

## 本番Rulesの変更差分

Firestore / Storageとも差分なし。最新の全文、active ruleset / release metadataを反映前後で照合し、不変を確認した。したがってlectureNotes、avatars、friends、classes、classReviews、career等の既存権限は変更していない。

Rules deployは実行していない。Phase 2全体は完全成功ではなく、**indexのみ成功、Rulesは安全性検証で停止**した状態。

## Rulesを停止した理由

既存Firestore Rulesには以下の全階層許可がある。

```rules
match /{path=**}/entries/{userId} {
  allow read: if true;
  allow write: if request.auth != null
               && request.auth.uid == userId;
}
```

AI用のrecursive `allow read, write: if false` を追加しても、既存許可と一致する `aiSources/{id}/entries/{uid}` 等を拒否できない。複数のmatchに一致した場合の許可はORで評価される。[Firebase公式Rules仕様](https://firebase.google.com/docs/rules/rules-behavior)

本番ユーザーデータに触れず、demo projectのローカルEmulatorに最新Rulesと架空データを入れたテストで、匿名readがHTTP 200になることを確認した。

ローカル修正候補は既存entriesのallow条件に「AI top-level collection以外」の条件を加えるもの。AI 5領域の直接操作を拒否し、classes / classReviewsの授業ごとのレビュー操作、lectureNotes、friends、avatars等の回帰は通る。しかし、従来許可されていた無条件の全体 `collectionGroup("entries")` queryがHTTP 403に変わる。

この候補は既存条文・検索権限に影響し、今回の「既存権限をすべて維持」と両立しないため、production設定に採用もdeployもしていない。現在のアプリソースではclassReviewsの授業ごとのパスを使用しているが、別クライアントの全体検索依存を存在しないとは断定しない。

追加したproduction wrapperガードは、この既知の重複許可を検出し、Rulesのplan / dry-run / deploy / approval hookを失敗させる。これは限定した既知パターンの検出であり、一般のRules安全性証明を置き換えない。修正時にも全面Emulator回帰を必須とする。

## テスト結果

| 対象 | 結果 |
| --- | --- |
| index対象・許可操作ガード | 2/2 PASS |
| production設定・保全・allowlist・既知Rules bypass防止 | 12/12 PASS |
| 最新本番Rulesの既存権限回帰 | 4/4 PASS |
| 承認済みadditive deny案 | 5 PASS / 1 FAIL: AI配下entriesを匿名read可能 |
| AI除外のローカル修正候補 | 5 PASS / 1 FAIL: 全体entries query権限が変わる |
| Rules dry-runの拒否 | 期待どおりSTOP。クラウド操作開始前に拒否 |

回帰対象: 公開classes / careerListings / circle、classes / classReviewsのレビュー操作・授業内一覧、全体entries query、users / lectureNotes / timetable / fcmTokens、friends・incoming request、avatars、AIの主要5領域、AI配下entries、ai-inputs / ai-derived Storage。

Firestore / Storage回帰で使用したデータ、read / write / uploadはすべてローカルdemo Emulatorのみ。本番Authユーザーや資料は使用していない。本番の主要AIパスの動作を実データでテストしたという意味ではない。

## 保持されたリソース

index追加前後でProject IAM、bucket IAM、Secret IAM、queue、Scheduler inventory、Function inventory・updateTime、bucket lifecycle / soft-delete、Rules、Secret最新versionを同一照合した。

- `aiProcessSource` queueはTokyo / PAUSEDのまま。
- `GROQ_API_KEY`はversion 1 / ENABLEDのまま。payload取得・表示なし。
- Functions、IAM、Rules、既存indexes / fieldOverrides、Storage objects、Firestoreユーザーデータ、Auth、lifecycleへの変更なし。
- queue resume、Scheduler作成・resume、Secret変更、`--force`、GitHubへのpush、main / PR merge、App Store公開なし。
- `Aogaku-clean`への変更なし。

## 次の判断

**Phase 3aへは進めない。** Phase 2bの設計競合が未解決。

1. 全体entries検索の互換性を保持する別構成を検討し、Phase 2bは保留する。
2. 全体entries検索を制限する影響を明示承認したうえで、AI除外条件の最小修正とproduction guardの限定更新をレビュー・検証する。

どちらも今回未実行。修正を採用する際は最新本番Rules / metadataを再取得し、差分承認と既存権限・AI遮断の回帰を経てPhase 2bだけを実行する。追加済みindexの再作成・削除・rollbackは承認なしでは実行しない。

## ローカル変更・証跡

- `scripts/deploy_production_phase2_index.cjs`: 追加indexだけの実行・前後保全・READY待機。
- `scripts/test_production_phase2_index.cjs`: 対象・index定義・禁止操作のガード検証。
- `functions/test/production.test.cjs`: classReviews・全体entries query・AI配下entriesの回帰追加。
- `scripts/firebase_production.py`: 既知のentries重複許可による不安全なRules反映を拒否。
- `scripts/test_production_safety.py`: approval receiptでも当該bypassを回避できないことの検証。
- 本書: 結果と停止理由。

非公開の証跡はGit除外の `build/production-phase2/` に保存した。`final-result.json`、index execution journal、metadata前後、保護リソース前後、Emulatorログ、ローカルcandidateと差分を含む。既存Dev設定・検証結果・AI入力変更を保持し、commit / pushはしていない。

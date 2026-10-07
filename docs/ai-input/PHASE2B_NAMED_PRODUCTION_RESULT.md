# Phase 2b 本番named database反映結果

2026-10-07 JST。ユーザーのPhase 2b承認に基づく実行。**Phase 2b完全成功、Phase 2全体完了。Phase 3は未実行で、追加承認待ち。**

## 対象・追加リソース

Project ID `forta-aogaku` / Project Number `505828754933` / default bucket `forta-aogaku.firebasestorage.app` / Release Bundle ID `com.forta2k25.Aogaku` を最新本番metadataとローカルRelease設定で再照合した。

新規database `projects/forta-aogaku/databases/aogaku-ai`：

- Native mode、asia-northeast1、DELETE_PROTECTION_ENABLED。
- UID `19af658b-3975-4d10-a161-3805375a250a`。新規作成し、再作成・移行・データ投入なし。
- client Rulesは全pathのread/writeを全面deny。namedの稼働Rules全文がConfig/AI/firestore.rulesと一致。
- aiSources(status ASC, updatedAt ASC) composite index 1件 READY。
- memberships.userIdのCOLLECTION_GROUP ASC設定1件。COLLECTION ASC/DESC/ARRAY_CONTAINSを保持し、全4設定がREADY。

## IAM・既存リソース

Phase 1のruntime / account-deletion SAはemail / project / uniqueIdを保存済み原本と再照合し、両方有効・user-managed key 0。custom role 6件の権限も照合した。

両SAにはPhase 1で承認・追加済みのproject-scope `roles/datastore.user`があり、named databaseにも適用される。**不足bindingなし、今回IAM差分0。** 既存project / bucket / Secret / runtime自身 / queueのpolicyを前後同一確認。条件付きbindingを重ねても既存project bindingの実効範囲は狭まらないため、冗長な追加は行っていない。既存権限を狭める変更は別承認対象。

defaultのFirestore Rulesは全文・releaseとも不変。既存4 composite index（Phase 2a追加AI indexを含む）、8 fieldOverridesはresource ID / 定義 / stateを含めて不変。REST一覧には標準の__default__設定も返るが、fieldOverrides 8件には含めない。

Functionsは既存13件のinventory / state / updateTime不変。GROQ_API_KEYの全version metadata不変、latest version 1 ENABLED。payload取得・表示、version追加・rotationなし。bucket lifecycle / soft-delete / IAM / default ACL不変。API / SA / queue / Scheduler / Eventarc metadataも前後不変。

Tokyo aiProcessSource queueはPAUSED、設定・IAMとも不変。Scheduler作成・resumeなし。

## Storage Rulesの唯一の差分

最新本番から取得した全文がbaselineと一致することを確認し、以下だけを追加した。avatars条文・他の既存挙動は保持。

```text
    // AI access is through authenticated server APIs only.
    match /ai-inputs/{path=**} { allow read, write: if false; }
    match /ai-derived/{path=**} { allow read, write: if false; }
```

稼働releaseが新rulesetを指し、取得した稼働全文と承認candidateが一致することを確認。default Firestoreのreleaseには触れていない。

## 実行順序・結果

1. 読取専用preflight：identity、Phase 1 IAM/SA/queue、default Rules/indexes、Functions、Secret、lifecycle、Rules compiler PASS。
2. named database作成→named全面denyのruleset / release作成→前後保全PASS。
3. named composite追加→membership field設定→両方READY待機→前後保全PASS。READY前にStorage Rulesへ進んでいない。
4. 最新Storage releaseを直前再取得→承認差分だけruleset作成 / release更新→前後保全PASS。
5. 最終metadata post-check→実client拒否→証跡集約PASS。

クラウド変更は合計7 API mutation：database作成、named ruleset/release作成、composite作成、membership field PATCH、Storage ruleset作成 / release PATCHのみ。API/IAM/Functions/Secret/queue/lifecycle/ユーザーデータ変更は0。

| 最終確認 | 結果 |
|---|---|
| named region / mode / delete protection | PASS |
| named必要indexes | 全READY |
| default Rules / 4 indexes / 8 overrides | 全不変 |
| 実本番entries匿名collectionGroup query | HTTP200、__name__のみ・limit1 |
| 実本番entries匿名document read | HTTP200、本文保存なし |
| named client direct read/write | 24件すべてHTTP403、匿名・canonical全領域＋不正nested entries |
| Storage AI direct read/write | 4件すべてHTTP403 |
| 認証owner / outsider / 匿名のRules回帰、avatars・既存権限・旧機能 | 同一Rules全文でEmulator 45/45 PASS、skip0 |
| Phase 2b操作allowlist / 禁止操作guard | 5/5 PASS |
| named database安全guard | 6/6 PASS |
| queue / IAM / Functions / Secret / lifecycle | 保持、PAUSED、差分0 |

認証ありの実ユーザーを作成・変更していない。認証ケースはEmulatorで検証し、実本番では稼働Rules全文一致と匿名HTTP確認を行った。avatarsの実ユーザー画像書換え、Auth変更、管理APIによるテストデータ書込みは行っていない。write拒否の実HTTP確認は全面deny照合後の新規synthetic pathだけで、すべて403となり保存されていない。

途中のpost-checkに1件のローカルharness errorがあった。既存entriesの親IDに`#`があり、未encode URLがfragmentとして切られ別pathへGETしたため403になった。変更操作を停止して読取専用で切り分け、resource segmentをencodeするとHTTP200。確認スクリプトだけを修正し、最終post-checkは全PASS。本番Rules / 権限のdriftではない。初回失敗ログと診断証跡も保持。

**cloud mutation error 0、unexpected drift 0、partial successなし。** `--force`、リソース削除、全Functions deploy、Phase 3以降は実行していない。

## ソース変更・証跡

- scripts/deploy_production_phase2b.cjs：named DDL / Rules / indexesだけの明示allowlist、対象照合、mutation journal、fresh release再照合、保護metadata前後一致、失敗時停止。IAM mutationを許可せず、不足検出時も自動変更しない。
- scripts/verify_production_phase2b.cjs：稼働Rules照合・実HTTP拒否・既存entries query/read、本文非保存・特殊文字encode。
- scripts/test_production_phase2b.cjs：allowlist・default/Functions/Secret/IAM/queue等の禁止操作検証。
- scripts/test_named_database_safety.py：旧inventory拒否テストを、実行後に更新されるlive snapshotへ依存しないfixtureに修正。
- 本書：実行結果。既存Dev実装・検証結果・backupは保持。

private証跡はGit除外のbuild/production-phase2b-named/に保存：baseline、各stage before/after、execution.json、final-result.json、稼働Rules/indexes、storage-rules.diff、client-postcheck.json、初回GET診断。build/production-phase2b-*.logにguard / compiler / regression / 初回・最終post-checkを保存。

branchはcodex/ai-input-main-integration、HEAD d3f56c6aeacb24f8c23a0c36c77d1feca29e230aを保持。commit / push / main merge / PR merge / App Store公開 / Aogaku-clean変更なし。

## 次の状態

Phase 2aのdefault追加indexは維持し、Phase 2bも完了した。Phase 3aの未公開旧AI3 Functions更新を、次の別承認対象として提示できる状態。新しいmetadata / artifactで対象3件だけを再照合して実行する必要があり、古い承認receiptは流用しない。

Phase 3b（削除3経路）、Phase 4（新AI12をclosed導入）、Phase 5（指定UIDのみ内部E2E）は未実行。一般ユーザーへの新AI解放、共有ONはしていない。今回完了したのは本番のデータ境界準備で、写真/OCR等の本番入力E2Eを完了したという意味ではない。

設計資料：[NAMED_DATABASE_ARCHITECTURE.md](NAMED_DATABASE_ARCHITECTURE.md)。公式仕様：[Rulesの管理API](https://firebase.google.com/docs/rules/manage-deploy)、[複数database](https://firebase.google.com/docs/firestore/manage-databases)、[Firestore IAM](https://firebase.google.com/docs/firestore/security/iam)。

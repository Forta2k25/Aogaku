> 2026-10-06: Phase2bはnamed database分離案へ変更。最新構成は [NAMED_DATABASE_ARCHITECTURE.md](NAMED_DATABASE_ARCHITECTURE.md) を参照。本書のdefaultへのAI Rules追加案・過去receiptは本番反映に使用しない。

# AI schema監査・Phase 2b再検証

2026-10-06。今回のproductionアクセス・変更・deployは0。Phase 2aで取得・照合済みの本番Rules全文を基準に監査した。

## 結果

**AI保存schemaに`entries`は元から存在しない。collectionの改名ではPhase 2bのblockerは解消しない。**

正規schemaの直接操作拒否と既存レビューの互換性は確認できた。一方、クライアントが任意のFirestore pathを選べるため、schema外の`aiSources/{id}/entries/{自分のUID}`を作成でき、匿名readも許可される。サーバーが使用する名前を`privateEntries`等に変えてもこの権限は変わらない。現在のAI本文やchunksが匿名で読めることを示す結果ではなく、要求された「AI全領域の直接read/write拒否」を満たさない結果。

厳格な境界テストは削除・skip・成功扱いにしていない。既存production Rules・全体`collectionGroup("entries")`を維持し、production deploy guardも維持した。**Phase 2bは再実行不可、Phase 3には進まない。**

## 変更前後のpath

すべて前後同一。資料ID・出典・年度snapshot・受付ID・データ移行に変更なし。

| 変更前＝変更後 | 用途 |
| --- | --- |
| `aiSources/{sourceId}` | 受付・状態・snapshot・削除tombstone |
| `aiSources/{sourceId}/jobs/{taskId}` | 再送・Tasks取消のledger |
| `aiSources/{sourceId}/runs/{runId}` | 解析runの親参照 |
| `aiSources/{sourceId}/runs/{runId}/chunks/{chunkId}` | OCR / ASR / メモ本文と出典 |
| `aiCourseOfferings/{courseOfferingId}` | 年度別授業snapshot |
| `aiCourseOfferings/{courseOfferingId}/memberships/{uid}` | verified membership |
| `aiCourseOfferings/{courseOfferingId}/lectures/{lectureId}` | 授業回 |
| `aiUsage/{uid}` | usage treeの親参照 |
| `aiUsage/{uid}/periods/{periodId}` | 日 / 週quota |
| `aiInputOwners/{uid}` | アカウント削除・受付停止marker |
| `aiMaintenance/accountSweep` | 削除再開cursor |

命名は既存の`chunks`（抽出本文の断片）、`runs`（解析実行）、`jobs`（queue処理）、`memberships`、`lectures`、`periods`を維持した。存在しない`entries`を改名したという記録や、不要なDevデータ移行は作っていない。

`functions/src/ai/schema.ts`へ名称とpathの一覧を集約し、Functionsの受付・本文保存・根拠検索・再送・削除・account deletion helperが同じ定数を使用するよう変更した。新しいAPI / Functionは追加していない。

## ソース・fixtureの確認

- AI FunctionsのFirestore collection呼び出しは登録定数に集約。唯一の既存カタログ参照`classes`はそのまま。
- iOS `Aogaku/AIInput/`にはFirestore collection / document呼び出しがなく、Callableを使用する。path名の変更は不要。旧レビューの`ReviewService.swift`は変更なし。
- 普通のEmulator / Dev fixture、出典取得、再送、削除、account deletion cleanupにはAI用`entries` pathなし。
- `functions/test/production.test.cjs`とDev E2Eの`schema-rules`にあるAI配下の`entries`は、クライアントがschema外のpathを選ぶ攻撃テスト。これを別名にすると実際の許可漏れを検証できなくなるため、明示的に攻撃probeとして保持した。
- `Object.entries`、LocalSyllabusIndexの配列名等はFirestore collection名ではないため変更なし。
- Storage原本`ai-inputs/`・派生物`ai-derived/`、端末保存・会話・添付の削除経路は維持。

## 本番Rules全文の静的監査

Firestore 16 match block、Storage 2 match blockを列挙し、親のprefixを含めて監査した。正規AI 11 document pathと既存grantの重なりは0。登録collection名とpath一覧の整合性も検証。

| recursive / 汎用grant | AIへの影響 |
| --- | --- |
| `/{path=**}/entries/{userId}` | 全rootに一致。任意のAI root配下の`entries`作成・匿名readを許す。未解決 |
| `/users/{uid}/{sub=**}/{docId}` | users配下の本人read/delete。AIの5 rootとは一致しない。AIをusers配下へ移す設計は採用しない |
| `/users/{otherUid}/{coll}/{docId}` | friends / requests等の限定grant。users prefixとcoll条件があり、AI rootには一致しない |
| classes / circle / careerListings / usernames / analytics_events等 | rootが固定。AI rootには一致しない |
| Storage `/avatars/{file}` | AIの原本 / 派生物prefixには一致しない |

この監査は取得済みbaselineに対する限定的なpattern監査で、一般のRules評価を代替しない。実際の挙動はEmulator / Devで検証した。

## ローカル / Emulator結果

- TypeScript build、recovered build: PASS。
- domain単体: 13/13 PASS。
- schema監査 / production guard / 環境分離: Python 24/24、Node 9/9 PASS。
- Swift端末保存: snapshot、復元・利用者分離、編集・削除、全媒体 / 会話 / 添付削除、保持callback無効化・再起動での復活拒否をPASS。
- 本番統合Rules + AI + 旧AI / ASR / 友人通知 + 削除 + rollout artifactのEmulator: **39 PASS / 1 FAIL / skip 0**。
- 正規AI 11 pathは匿名・owner・outsiderでread/write/deleteすべて403（99 checks）。既存entriesの匿名read・授業内操作・全体queryは成功。
- FAILはschema外のentries境界テストだけ。Adminでの事前作成なしでも、本人UIDのclient PATCHが200、その後匿名 / owner / outsiderのreadが200になることを5 rootすべてで確認した。

## Dev実通信結果

対象は`forta-aogaku-dev`のみ。既存Dev稼働版のpathは今回も同じ。今回の定数集約版はローカルbuild / Emulatorで実行し、DevのFunctions / Rulesの新規deploy・schema移行は行っていない。

**13 PASS / 1 FAIL**。

| 対象 | 結果 |
| --- | --- |
| メモ、写真Vision OCR、PDF text / OCR / page出典、録音Groq / timestamp、本人一覧・検索 | 4/4 PASS |
| 注入した失敗 → aiRetrySource → 同じ受付 → 本文・検索 | PASS |
| upload中断 → 再送、upload中削除、解析中削除 | 3/3 PASS |
| 共有OFF、verified memberでも取得不可、本人根拠取得 | PASS |
| preDeleteCleanup → client Auth delete / server削除 / Auth triggerの3経路 | 3/3 PASS |
| lectureNotes / avatars / AI主要path / indexes / overridesの回帰 | PASS |
| 全schema + 既存entries + schema外境界probe | FAIL: 任意entries pathのclient作成・匿名readを許す |

削除3経路では使い捨てUIDだけを使用。受付停止、Tasks実取消、原本 / 派生物 / jobs / usage / 旧quota / nested旧会話・note削除、遅延upload除去を確認。quota再生成防止・遅延worker拒否は最新Emulatorの旧AI / ASR回帰でもPASS。

Devのschema probe詳細:

- 正規schema 11 path × 3認証状態の33 read/writeペアはすべて403。
- 既存レビューの本人write・匿名read・全体entries queryの3 checksはすべて200。
- schema外の5 AI rootで本人client作成・匿名readが200。
- probeで作成したAI 5件 + 既存レビュー互換性用1件は、run marker一致を確認して6件すべて削除。一般のDev資料や本番資料は使用していない。

実行環境の初回エラー（Firebase CLIライブラリ探索先、Swift cacheの書込先）は既存インストールの明示・workspace cache指定で解消。未解決のAPI / OCR / ASRエラーではない。

## Phase 2b差分と残条件

取得済みの最新本番baselineからFirestore / Storage diffを再生成した。既存条文は一切変更せず、従来案のAI 5 root / Storage 2 prefixへのdeny追加のみ。Firestore案は全領域遮断を証明できないため**承認artifactではなくBLOCKED候補**として保存した。

本番追加済みindex `CICAgNjpgYIK` の削除・再作成・更新なし。index設定も不変。production deploy guardの既知entries overlap拒否は解除していない。

既存entries条文と全体queryを完全維持し、任意のAI pathも拒否するには、AI用の独立したFirestore database等の境界を検討する必要がある。Firestore Rulesはdatabaseごとに設定できる。[Firebase公式database管理](https://firebase.google.com/docs/firestore/manage-databases)、[Rulesのdatabaseごとの設定](https://firebase.google.com/docs/firestore/security/get-started)

提案は同一project内のAI専用named database。ただし今回は設計案までで、database作成・接続変更・移行は実施していない。採用時には別途以下を設計・検証する。

1. 旧classes / users / quota / friendsは(default)に保持し、新AI source / usage / marker等を専用databaseへ分離。
2. AI専用databaseのclient Rulesを全面deny。既存(default)のentries grant / queryは維持。
3. database ID / region / IAM / deploy guardを明示し、Admin SDKのdefault暗黙接続を禁止。
4. classes参照、account deletion、旧quotaのtombstone参照を分離後の構造に適合。databaseを跨ぐtransactionは使わず、削除受付停止・再開可能cleanup・quota再生成防止を再検証。
5. 既存本番index4件 / overrides8件を保持し、専用databaseで必要なAI indexだけを別承認で追加。
6. Devの既存資料・端末台帳・検証結果を保持し、database切替時の識別・移行方針を明示してE2Eを再実行。

今回は本番データ / Rules / indexes / IAM / API / Functions / queue / Scheduler / Secret / lifecycleへのアクセス・変更なし。GitHub push、main / PR merge、アプリ公開、Aogaku-clean変更なし。共有OFFを維持。

## 今回の変更ファイル

- `functions/src/ai/schema.ts`: collection名とdocument pathの登録。
- `functions/src/ai/index.ts`: 保存・検索・再送・削除helperが同じcollection定数を使用。
- `functions/test/production.test.cjs`: 全schemaの拒否検証、Admin seedなしの不正entries作成probe。
- `scripts/audit_ai_firestore_schema.py` / `scripts/test_ai_schema_audit.py`: 全baseline Rulesのpattern / prefix監査とschemaの検証。
- `scripts/dev_e2e.cjs`: Dev限定schema・既存entries・任意pathのprobe、run markerによる後処理。
- `docs/ai-input/README.md` / `API.md`: 保存schemaと保護範囲を明示。
- 本書: 結果・停止理由・未実施の分離案。

生成JS、Swift cache、Emulator fixture、Dev認証情報・実行結果はソースから分離し、Git除外の`build/ai-schema-audit/`に保存。以前のDev証跡も退避済み。commit / pushはしていない。

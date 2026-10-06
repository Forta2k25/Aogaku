# 最新mainへのAI入力統合・再検証（2026-10-06）

指定された最新mainへ統合し、要求された自動検証をすべて完了した。GitHubへpush・PR・mergeしていない。本番Firebaseへの読み取り・変更・deploy、`Aogaku-clean` の変更も行っていない。ここで作業を停止する。

## 保存と統合

| 項目 | 結果 |
|---|---|
| main基点 | `9d596f7b421e81df6776d4d337eb4c650231f371`。`git fetch origin` に加え、単一ブランチcloneのためmainを明示取得し、指定HEADと一致を確認 |
| 元のAI基点 | `47d54c8c03247c9311acc0c3d7bcdd2f5046a997` |
| AI保存commit | `ed4e424fde21575489cfac5b46f5b0409caa76ef`、元コピーの `codex/ai-input-foundation`。ソース・非秘密設定・ドキュメント59ファイルを保存 |
| cherry-pick後commit | `941dd3c8b83157873f812ba217fb74915c9ed0f0` |
| 統合ブランチ | `codex/ai-input-main-integration`。main自身は変更していない |
| 統合作業コピー | `/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku-main-integration` |
| Xcode | 上記コピーの `Aogaku.xcodeproj`。通常 `Aogaku-Dev` / Debug、実サービスE2E `Aogaku-AI-Dev-E2E` |
| Simulator | iPhone 17 / iOS 26.0、UUID `461FE933-297E-4B76-B530-E3BEF18B34EB` |

最初に `/Users/shum/Documents/Codex/2026-10-06/y/work/ai-input-backup-20261006-main-integration` へ元index、staged/unstagedのbinary patch、ソースpatch、Git状態、作業ツリー（Dev設定・過去E2E記録を含む）、node_modulesの別archiveを保存した。バックアップは非公開のローカル保存で、秘密設定を含むarchiveを共有・commitしない。SHA-256を再照合し、ソースarchive内の59ファイルとAI保存commitも全件一致を確認した。共有可能な保存commitのpatchは `source-commit.patch`。

元コピーは残し、別のGit worktreeで統合した。元のDev E2E結果・端末fixtureを削除していない。新コピーでも旧記録を `scripts/output-dev/e2e-state-before-integration.json` と `e2e-results-before-integration.json` に保持し、今回用の新しい授業・受付IDで再検証した。Authは既存の架空テスト利用者3名を使用。本番データはコピーしていない。

## conflictとmain機能の保持

conflictは **`Aogaku.xcodeproj/project.pbxproj` のみ、3か所**。mainの `MARKETING_VERSION = 2.2.0` と、AI側のDebug Bundle ID変更が隣接していた。

| conflict箇所 | 解決 |
|---|---|
| Widget Debug | mainの2.2.0を保持し、`com.forta2k25.Aogaku.dev.AogakuWidgets` を採用 |
| Action Debug | mainの2.2.0を保持し、`com.forta2k25.Aogaku.dev.AogakuAction` を採用 |
| App Debug | mainの2.2.0を保持し、`com.forta2k25.Aogaku.dev` を採用 |

App/Widget/ActionのDebug・Release全6設定が2.2.0。ReleaseのBundle ID・App GroupはAI実装による変更なし。Debug App Groupは `group.jp.forta.Aogaku.dev`。生成アプリでもバージョン2.2.0、Dev Bundle ID、同梱Firebase configがDevのみであることを確認した。

main更新の以下6ファイルは `origin/main` と**バイト単位で完全一致**を確認した。就活・留学・バイト・イベントのカテゴリ、検索、保存済み／ブックマーク、締切間近・NEW表示、掲載元別の応募導線と登録スクリプトを保持している。キャリアUI全操作の実通信テストは今回のAI検証には含めない。登録スクリプトは実行していない。

- `Aogaku/CareerBookmarkStore.swift`
- `Aogaku/CareerDetailViewController.swift`
- `Aogaku/CareerListViewController.swift`
- `Aogaku/CareerListing.swift`
- `Aogaku/CareerListingCell.swift`
- `scripts/add_career_listing.js`

AI保存commitとの差はmain更新7ファイルと、今回のテスト／報告補修だけ。`Aogaku/` の既存授業チャット、`AogakuAction/`、`AogakuWidgets/`、`shared/`、Functions、Firebase設定を比較し、保存済みAI機能を欠落させていない。写真・PDF・メモ・録音、端末保存／復元、会話・添付・送信ID復元、状態表示／再送、共有／撤回、所属権限、削除／復活防止、OCR／ASR、出典付き根拠検索を維持した。

## ビルド・ローカルテスト

| 検証 | 結果 |
|---|---|
| iOS Debug build | `Aogaku-Dev`、Simulatorローカル署名、**BUILD SUCCEEDED** |
| TypeScript build | `tsc` 成功 |
| Functions単体テスト | 10件成功、失敗0 |
| Firebase環境分離 | 9件成功、失敗0 |
| Dev API通信先・Secret安全ガード | 5件成功、失敗0 |
| ローカルEmulator | 6件成功、失敗0、skip 0。認証拒否・共有撤回・受付重複／利用者／年度分離・所属検証・worker重複／削除・直接read拒否 |
| Swift保存層 | 受付ID、再構築後復元、利用者分離、会話編集時の資料保持、削除意図復元と端末削除、すべて成功 |
| Simulator E2E | XCTest 1件成功、失敗0、7.694秒。4入力の実保存・upload・本文／出典・根拠検索まで成功 |

ローカルEmulatorテストでは、前回のDev対応で追加されたworker URI取得に代替処理がなくADCへ進む問題を見つけた。**テスト側だけ**でADC token、worker metadata、Tasksの輸送を置き換えた。Firestore・Storageは `demo-aogaku-input` のローカルEmulatorを使用し、想定外の外部fetchは拒否。受付・transaction・worker・権限・削除のロジックは本物の実装で検証する。初回の代替credentialはFirestoreが受け付けないため、ADCの型を保持してtoken取得だけを置き換え、最終6件すべて成功。利用上限で実行されなかった検証は再開後に実行した。

## Dev実通信E2E

対象は **`forta-aogaku-dev` / `1064661805206` / `forta-aogaku-dev.firebasestorage.app` のみ**。CLI・REST・iOSで接続先を照合した。秘密値をログ・ソース・plist・報告に保存しない。GroqはDev Secret Manager、VisionはADC/IAMを継続使用。

| シナリオ | 結果 |
|---|---|
| メモ → 受付 → 本文 → 一覧 → 出典付き検索 | PASS |
| 写真 → 新規署名upload → Vision OCR → 一覧 → 出典付き検索 | PASS |
| PDF → 新規upload → 2ページの本文抽出／Vision OCR → ページ出典 → 検索 | PASS |
| 録音fixture → 新規upload → Groq ASR → 時刻出典 → 検索 | PASS |
| 同じ授業へ共有 → 所属利用者が閲覧 → 撤回後に閲覧／検索不可 | PASS |
| 他授業利用者・他人の削除・所属の自己承認・原本直接アクセス拒否 | PASS |
| 同じ受付IDの重複送信 → 同一資料、本文変更したID再利用は拒否 | PASS |
| uploadを途中abort → 未完了検出 → 同じIDで再送 → ready | PASS |
| upload開始 → 削除 → upload完了 → 原本除去・復活なし | PASS |
| 実際にextracting/indexingを観測 → 削除 → 原本／派生物／検索から除去 | PASS |
| 削除済みURLの遅延upload → Storageトリガーで除去、再受付拒否 | PASS |
| 架空資料への失敗状態注入 → 実 `aiRetrySource` → 同じIDで再処理 → ready／検索 | PASS |

実APIハーネスは11チェック（表の一部をまとめた検証）、すべてPASS。失敗状態の注入は今回作成した架空資料1件のみで、実プロバイダー障害の再現とは区別する。新規音声は合成録音fixtureであり、人がマイク操作して録った実録音ではない。

Functionsのソース・package/lock・Rules/indexesは、元コピーの検証済みDevデプロイと一致するため**再deployは不要で、実行していない**。今回の補修はテストと文書のみ。既存本番Functionsや本番ユーザーデータへアクセスしていない。

## 記録・変更ファイル・残課題

検証ログ（統合作業コピーと同じ親ディレクトリ）：

- `integration-debug-build.log`
- `integration-ios-e2e.log` と `IntegrationDerivedData/Logs/Test/` のxcresult
- `integration-local-tests.log`
- `integration-emulator.log`
- コピー内 `scripts/output-dev/e2e-results.json`（Git除外、認証情報なし）

`scripts/output-dev/e2e-state.json` と `AogakuTests/DevFixtures/` には架空利用者の認証状態を含むため共有しない。Dev plist・manifest・Functions envもGit除外を再確認した。元からGit追跡されている `functions/node_modules` / `functions/lib` の生成差分は、ソースcommitに含めずローカルに残す。新しい生成物・Dev E2E実行結果もソース変更と分離した。削除して既存状態を失う操作はしていない。

cherry-pickの59ファイル以外の今回の追加変更：

- `functions/test/emulator.test.cjs`：worker URI／ADC輸送をテスト内で置き換え、実クラウド接続を防止。
- `scripts/dev_e2e.cjs`：失敗資料の実再試行チェック追加。FAIL/BLOCKEDがある実行は終了コード1にする。
- この報告、`README.md`、`E2E_CHECKLIST.md`、`SIMULATOR_AND_DEVELOPMENT.md`、`DEV_CONNECTION_AND_RESULTS.md`：最新main統合後の結果と場所を明示。統合前の検証履歴は保持。

**要求された実施テストに未解決の失敗なし。** 残る確認は、写真／PDFピッカー・マイクの手動操作、実機の長時間録音・画面ロック・バックグラウンド・着信・強制終了・実際の圏外復旧、429/5xx・quota・Scheduler/lease期限などの障害条件。AI回答生成UIは今回の根拠検索API検証に含まない。17分音声の分割検証は統合前の成功記録を保持しており、今回の再実行対象は短い音声とiOSの4入力。

GitHubへのpush・PR・mergeと本番へのアクセスは別途指示があるまで行わない。

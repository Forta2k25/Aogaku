# 年度別授業ID・snapshot実装と検証（2026-10-06）

指定された授業識別仕様へ変更した。作業コピーは `/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku-main-integration`、ブランチは `codex/ai-input-main-integration`、main基点は `9d596f7b421e81df6776d4d337eb4c650231f371`。既存保存commit `ed4e424` と統合HEAD `d3f56c6` を維持し、今回の追加変更はローカルの未commit変更として残す。この追加変更のGitHub push・PR・merge・リリースはしていない。

## 実装した識別仕様

| 項目 | 動作 |
|---|---|
| canonical offering | `{year}:{5桁classDocId}`。例 `2026:00004`。先頭0を維持し、翌年度は別ID |
| 年度 | 保存するsyllabus URLの唯一かつ有効な `YR` → 時間割の明示年度 → null/unresolved。現在年のfallbackなし |
| semester | snapshotとlectureIdに保持。年間courseOfferingIdには含めない |
| snapshot | courseOfferingId、classDocId、year、semester、syllabusUrl、courseName、teacherName、localCourseUUID、resolution、yearSource |
| docID欠損／年度未解決 | `local:{SHA256(AuthUID,localCourseUUID,year-or-null)}`。code・仮code・授業名・教員名を識別子として使わない |
| 新規ローカル授業 | Course生成時にUUIDを付与し、端末Codableと時間割mapへ保存 |
| 旧時間割のUUID欠損 | ローカル保存領域でUUIDを一度付与して保存。remote legacyは所有者・学期・セル保存アドレス／更新revisionで初期化し、code/nameによる自動同一視をしない |
| sourceId | 所有者＋既存clientRequestIdのhashを維持。courseOfferingIdの形式変更で受付IDは変えない |

時間割側の一般検索・レビュー等で使う既存 `Course.id` は維持したが、AI入力の識別には使わない。Firestore docIDは厳密な5桁数字。YRが重複・不正・範囲外の場合は有効なURL年度として採用せず、明示時間割年度へ進む。年は従来の入力検証範囲2000〜2100。

端末の `AIStoredSource.courseSnapshot` とCloudの `aiSources/{sourceId}.courseSnapshot` に保存時の情報を保存する。端末context・snapshotは更新処理でも上書き禁止。表示名の変更で会話や添付の所属が変わらないよう、会話の照合はcourse ID／学期／授業日で行う。

新規受付でURLが欠損している場合、現在のclassesからURL・表示名を補完できる。ただし時間割年度と現在のカタログYRが異なる参照は `CLASS_YEAR_MISMATCH` で停止し、再利用されたIDへの誤登録を防ぐ。既に保存した旧URLを持つ過年度のcontextは旧YRを使用する。消えたclassesを参照する新規受付は既に保存された年間offeringが必要。

一覧lookupは保存済みcontextのURL／年度か、受付で返したoffering IDを使用し、現在のclassesを読んで再決定しない。カタログ補完で年度が初めて判明したAPI利用者は返却snapshotを保持して後続検索に使う。年・URLの両方が実際に不明な資料はunresolvedのまま個人利用できる。

既存受付の再送は、fingerprint・削除状態を先に確認し、classesを再参照しない。旧DevのハッシュID・既存receiptは読取り／検索／再送可能。仮codeを新UUIDに置き換えて既存資料を自動移行する処理は追加していない。

## 明示的なcanonical紐付け

新API `aiLinkSourceOffering` は所有者だけが呼べる。資料一覧の「授業IDを確定…」で5桁IDを指定し、現在のclasses URLのYR（欠損時は既知年度／入力年度）を使う。既知の保存年度と違う場合は拒否する。処理中資料は完了後に操作する。

移動するのは選択資料の参照先courseOfferingId／lectureId。元のcourseSnapshot、sourceId、fingerprint、本文・出典は保持し、確定時のcanonicalSnapshotを別に保存する。共有はprivateへ戻す。他の資料のCloud紐付けを一括変更しない。同じ操作を再送しても最初のcanonicalSnapshotを維持し、カタログの翌年更新で置き換えない。別offeringへの再紐付けは拒否する。

端末には利用者・UUID・元年度ごとの明示的対応を保存し、以後の入力でcanonical snapshotを利用する。以前のローカル会話・資料は元のsnapshotを残して表示できる。共有を設定するtransaction内でも最新のoffering membershipを確認し、紐付け変更との競合で別授業の所属が使われないようにした。

授業内の「保存履歴」から端末内の全保存資料（過年度・未解決・旧形式を含む）を確認できる。旧形式で所属を推測できない資料は、表示元の授業情報を確認したうえで新しい資料としてコピーできる。元資料は残し、新しい受付IDで保存・送信する。これは同じ資料を無断で別年度へ移す処理ではない。

## 検証結果

| 検証 | 結果 |
|---|---|
| TypeScript build | 成功 |
| Functions単体 | 13件成功、失敗0 |
| Firestore/Storage Emulator | 8件成功、失敗0、skip0。demo-aogaku-input。ADC／Tasks／worker metadataの輸送を代替し、想定外の実クラウドfetchを拒否 |
| Firebase環境分離・Dev安全ガード | 9＋5件成功、失敗0。追加deploy操作も専用wrapperでDevのみ許可 |
| Swift端末保存 | 成功。URL年度優先、年なしunresolved、UUID分離、Swift/Node ID一致、snapshot永続化、legacy decode、明示的対応の再起動後復元、表示名変更時の添付維持、以前の復元／利用者分離／削除 |
| Simulator XCTest | UUID／旧時間割の永続化と、4入力の実upload・本文・出典・検索の2テスト成功、失敗0 |
| Simulator Debug build | Aogaku-Dev / Debug成功。Xcodeの正確なパスは下記 |
| Dev年度識別E2E | URL YRが時間割年度に優先、同じ5桁IDの2026→2027再利用、旧snapshot／一覧／検索／再受付保持、docID欠損UUID分離、年度不明unresolved、明示的紐付けと他owner拒否、再紐付けのsnapshot固定、すべてPASS |
| Dev回帰E2E | メモ、写真Vision OCR、PDF本文＋OCR、Groq ASR、根拠検索、共有／撤回、権限、重複受付、PUT中断後同receipt再送、upload中削除、実解析中削除、遅延uploadの除去、失敗状態から実再試行、すべてPASS |

Dev APIハーネスは年度識別を含む12シナリオ相当。記録は初回の年度識別検証も残すため13 PASS、FAIL/BLOCKED 0。Simulatorの4入力テストもDev実通信。音声は架空の録音fixtureで、実機マイクの長時間録音ではない。再試行の失敗状態注入は今回作成した架空資料だけ。

開くプロジェクト：`/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku-main-integration/Aogaku.xcodeproj`。通常Schemeは `Aogaku-Dev`、ローカル通信なし確認は `Aogaku-AI-Local`。

## Devへの反映とデータ保存

対象は `forta-aogaku-dev` / `1064661805206` / `forta-aogaku-dev.firebasestorage.app` のみ。Dev専用wrapperでProject ID・番号・bucket・Bundle IDを確認し、AI受付API10関数だけを更新／追加した。再送のsnapshot固定補修では `aiLinkSourceOffering` 1関数のみを再更新。Rules、indexes、既存友人通知、worker／Scheduler／Storageトリガーをdeploy対象にしていない。

E2Eは未使用の5桁class IDをcreate-onlyで作成し、testRunIdを確認した今回所有の架空クラスだけを年度更新した。既存のDev授業を上書きせず、本番データも使っていない。

旧結果・認証fixtureは `../offering-identity-backup-20261006/`（非公開・Git外）にも保存。元 `scripts/output-dev/e2e-state.json` / `e2e-results.json` はそのまま、新結果は `e2e-state-offering-v2.json` / `e2e-results-offering-v2.json`（いずれもGit除外）。XCTest用の旧認証fixtureはバックアップし、新しい架空context用へ更新した。キー・認証値をソースや報告へ保存していない。

ログは作業コピーの親ディレクトリの `offering-debug-build.log`、`offering-ios-e2e.log`、`offering-emulator.log`、`offering-dev-*.log`。Dev E2E実行時はこのMacの既存Firebase CLI libraryを `FIREBASE_TOOLS_LIB=/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib` で指定した。初回はlibrary探索のMODULE_NOT_FOUNDを修正して再実行し、最終検証は成功。

## ソース変更一覧と理由

- `Aogaku/AIInput/SourceModels.swift`：年度解決・snapshot・年間ID・legacy互換・永続UUIDの初期化。
- `Aogaku/AIInput/LocalSourceStore.swift`：保存snapshotの固定、明示的対応の保存、会話／添付の照合。
- `Aogaku/AIInput/SourceIngestionService.swift`：紐付けAPI呼出しと利用者向けエラー。
- `Aogaku/AIInput/SourceLibraryViewController.swift`：ID確定、保存履歴、確認付きコピーの導線。
- `Aogaku/AIInput/AIInputPreviewViewController.swift`：確認用UUIDを固定して再起動後の資料を維持。
- `Aogaku/Course.swift`、`CourseStore.swift`、`TermStore.swift`、`timetable.swift`：登録授業のUUID付与・保存・旧保存形式の読込み／同期。
- `Aogaku/CourseDetailViewController.swift`：codeの代わりにUUIDと保存時の授業情報を入力contextへ渡す。
- `functions/src/ai/domain.ts`：URL年度・snapshot・年間IDとoffering専用ID検証。source/path IDの検証は緩めない。
- `functions/src/ai/index.ts`：保存時snapshot、旧受付の固定、一覧／検索、明示的紐付け、共有transactionでの所属確認。
- `functions/src/index.ts`：新Callableのexport。
- `functions/test/domain.test.cjs`、`functions/test/emulator.test.cjs`：年度違い／ID再利用／欠損／明示的操作／旧受付の回帰。
- `scripts/test_ai_store.swift`、`AogakuTests/AIInputDevIntegrationTests.swift`：端末・旧時間割UUID・snapshot・実4入力テスト。
- `scripts/dev_e2e.cjs`、`scripts/prepare_dev_ios_e2e.py`：5桁架空クラス、新context・年度更新の実通信テスト、旧結果分離。
- `scripts/firebase_dev.py`：Devだけの受付API／紐付けAPI deploy操作。既存本番拒否を維持。
- `docs/ai-input/API.md`、`README.md`、`E2E_CHECKLIST.md`、この文書：現行仕様・検証結果を更新。

生成された `functions/lib` / `functions/node_modules`、Dev plist／env／認証fixture／E2E実行結果はソース変更と分離し、commitに追加していない。Xcode project、App Group／entitlements、Widget／Actionの設定は今回変更していない。

## 残る確認・導入条件

要求された年度識別の自動検証に未解決の失敗はない。Simulatorで「授業IDを確定」「保存履歴からコピー」の手動タップは今回未実施。実機の長時間録音・着信／強制終了／圏外、プロバイダー429/5xx等の実障害は従来の残項目。

本番の履修membership連携、既存有効Rules／indexを残す導入案、旧AI・アカウント削除との共存、Cloud Tasks／Scheduler／Vision等の本番準備は別途残る。今回のコード変更だけで本番導入可能とはしない。過年度のカタログ表示情報を持たない旧資料の所属をcode／授業名で推測して自動移行しない。

**本ターンで本番Firebaseへのアクセス・変更・deployは一切なし。Aogaku-clean・main・GitHubは変更していない。Dev設定・過去E2E結果・保存済みAI実装を保持した。**

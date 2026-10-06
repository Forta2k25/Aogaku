# Dev接続・E2E実施結果（2026-10-06）

Devへの接続・12個のAI Functionsのデプロイと、4種類の入力の実通信検証を完了した。SimulatorのiOS保存・送信サービスからの検証も成功。手動での全ピッカー操作・実機のマイク録音や中断条件の確認は別途必要。

## 作業場所・安全境界

- 作業コピー：`/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku`
- ブランチ：`codex/ai-input-foundation`
- HEAD：`47d54c8c03247c9311acc0c3d7bcdd2f5046a997`（変更なし）
- Xcode：`Aogaku.xcodeproj`。通常の接続確認はScheme `Aogaku-Dev` / Debug、接続なしのUI確認は `Aogaku-AI-Local`。
- 実行先：iPhone 17 / iOS 26.0、UUID `461FE933-297E-4B76-B530-E3BEF18B34EB`。
- 本番Firebaseへの読み取り・変更・deployは行っていない。`Aogaku-clean`・GitHubに変更なし。commit・stage・push・PR・mergeなし。以前から存在するstaged変更は保持した。
- CLIは毎回Dev IDを指定。predeployでもIDを照合。プロジェクト番号・bucket・Bundle IDをローカル照合し、クラウドでもDevプロジェクト番号を確認した。
- DebugのFirebase SDK接続先は実行時にも `forta-aogaku-dev` に固定。署名PUTの送信先は現在のFirebase bucketだけに限定。
- DebugのApp Groupは `group.jp.forta.Aogaku.dev`。既存アプリ・拡張の本番共有領域と分離した。ReleaseのApp Groupは変更していない。

## 配置した設定

| 項目 | 値・保存先 |
|---|---|
| Project ID / number | `forta-aogaku-dev` / `1064661805206` |
| iOS Bundle ID | `com.forta2k25.Aogaku.dev` |
| Firestore / Storage / Functions / Tasks / Scheduler | `(default)` / `forta-aogaku-dev.firebasestorage.app` / `asia-northeast1` |
| Dev plist | `Config/Firebase/Development/GoogleService-Info.plist` |
| 承認済みDev manifest | `Config/firebase-development.json` |
| Functions非秘密パラメータ | `functions/.env.forta-aogaku-dev` の `AI_RUNTIME_SERVICE_ACCOUNT` |
| Groq | Dev Secret Manager `GROQ_API_KEY`、有効なversion 1を確認。ユーザー自身が登録 |

実設定3ファイルはGit除外・mode 0600。Groqキーをソース・plist・チャット・テスト結果に保存していない。運用ツールはsecret値の取得を拒否する。音声処理workerだけがADC/IAMでSecret Managerの値を取得し、Groqの認証に使用する。VisionもADC/IAMで認証し、JSON秘密鍵を作成していない。

署名なしでのDebugビルドは成功したが、Firebase AuthのKeychain操作は署名なしSimulatorで失敗した。最終のiOS E2EはSimulator用ローカル署名で成功。`CODE_SIGNING_ALLOWED=NO` を認証テストに使用しない。今回の署名エラーを起こしたFinder情報は、作業用パッケージキャッシュと生成ビルド製品だけから除去した。Debugの設定準備phaseは任意の環境ファイルを読むため、アプリtargetのDebugだけ `ENABLE_USER_SCRIPT_SANDBOXING=NO`。Firebase環境照合・接続ガードは保持。

## Devに設定したサービスと権限

次のAPIを有効化・確認：Firebase、Identity Toolkit、Firestore、Firebase Rules、Storage、Cloud Functions、Cloud Run、Cloud Tasks、Cloud Scheduler、Secret Manager、Vision、IAM、IAM Credentials、Eventarc、Pub/Sub、Cloud Build、Artifact Registry、Logging。Firebase CLIがFirebase Extensions管理APIも有効化した。

実行SA：`aogaku-ai-runtime@forta-aogaku-dev.iam.gserviceaccount.com`。

- Devプロジェクト：Datastore User、Cloud Tasks Enqueuer、Service Usage Consumer、Cloud Functions Viewer（同じDev workerのURI取得）、Eventarc Event Receiver。
- Dev bucketだけ：Storage Object Admin。
- 自身のSAだけ：Service Account User、Service Account Token Creator（OIDCの実行主体・署名URL生成）。
- Dev `GROQ_API_KEY` だけ：Secret Manager Secret Accessor。
- Dev `aiProcessSource` / `aiRejectLateUpload` / `aiReconcileInputs` のCloud Runサービスだけ：Run Invoker。
- Dev Storageサービスエージェント：Pub/Sub Publisher（Storage/Eventarc配送）。既存IAM bindingと条件・etagを保持して追加した。

設定済み：

- AI用12 Functionsのみ。既存の友だち・通知Functionsはデプロイしていない。
- Cloud Tasks `aiProcessSource`：最大同時実行3、最大試行4、backoff 30〜300秒。
- Scheduler `firebase-schedule-aiReconcileInputs-asia-northeast1`：15分ごと。
- Storage finalizeトリガー `aiRejectLateUpload`。
- Firestore Rules、`aiSources` の `status + updatedAt` index、Storage Rules。
- Dev音声原本の1日削除lifecycle。既存設定は保持。bucketのsoft deleteは既定7日が残るため、論理削除後も復元可能な保存と費用が最大7日残り得る。
- Dev Artifact Registry：コンテナイメージの1日cleanup policy。

Cloud Runへのtask送信は同じプロジェクトのworker URIを取得して指定する。[Firebase公式Tasks手順](https://firebase.google.com/docs/functions/task-functions)に沿ってOIDC主体へ呼び出し権限を設定した。

## 成功した実通信テスト

実際の授業資料・写真・ユーザー録音は使用していない。架空の日本語資料と合成音声を使用した。

| テスト | 結果・根拠 |
|---|---|
| メモ | 受付 → 本文保存 → 一覧 → 根拠検索。UTF-16文字位置 `0–58` |
| 写真 | 署名PUT → Vision OCR → 一覧 → 根拠検索。`imageIndex:1`、`vision_ocr` |
| PDF | 2ページとも成功。1ページ目 `pdf_text`、2ページ目 `vision_ocr`、pageNumber 1/2を保存 |
| 短い音声 | 原本保存 → FFmpeg → Groq → 根拠検索。時刻 `0–12,220ms` |
| 17分の合成音声 | 15分分割で2区間とも成功。資料として検索でき、出典APIのページングで195断片・最大1,018,828msまでの時刻を取得 |
| iOS Simulator実サービス | `LocalSourceStore` → 再構築後の送信ID保持 → `SourceIngestionService` → 4種類の署名PUT/完了 → ready → 出典検索。XCTest 1件成功（10.976秒） |
| 同一受付の重複 | source IDは同一。本文変更したID再利用は拒否。署名PUTの上書きは412 |
| 共有・撤回 | 検証済み同じ授業の利用者だけ閲覧。撤回後は本文・検索から参照不可 |
| 他授業の利用者 | 本文取得不可。他人の削除も拒否 |
| Firestore / Storage Rules | AI管理文書の直接読み取り、自分による所属検証の書き込み、原本の直接読み取りは403 |
| HTTP送信中断・再送 | アップロードを途中でabort → 未完了を検出 → 同じ受付IDで再送 → ready |
| アップロード中削除 | 送信開始後に削除 → 送信完了 → Storageトリガーが削除。資料復活なし |
| 解析中削除 | 実際にextracting/indexingを観測して削除。原本・派生Storage・検索から消え、復活なし |
| 遅延アップロード | 削除後に発行済みURLでupload完了しても原本は削除され、削除済みIDの再受付も拒否 |

検索の検証対象は `aiRetrieveContext` の根拠取得。AI回答を生成するUIは今回の対象外。
長い資料は検索APIの1資料80断片上限により省略され得る。17分音声の後半時刻を確認したのは `aiGetEvidence` の全ページ取得であり、検索の1回の応答に全195断片が入ることは保証しない。

## 失敗と修正

最終時点で、実施した通常入力・権限・再送・削除テストに未解決の失敗はない。

1. CLIのログイン失効：ユーザーによるGoogle再認証で解消。
2. 初回Functions基盤：workerのソースbucket作成409・Eventarcの初回権限反映待ち。対象2 Functionsだけ再デプロイして解消。
3. PDF：PDF.js 6のDocumentProxyに `destroy()` がなく終了処理で失敗。LoadingTaskの `destroy()` へ変更。日本語CMapと標準fontのパッケージ内パスを指定し、旧checkpointを再利用しないPDF専用キーへ更新。[PDF.js終了処理](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib-PDFDocumentLoadingTask.html)、[CMap設定](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib.html)。**同じ失敗資料の再送で成功を確認**。
4. Groqキー未登録：音声原本を保持したまま `ASR_NOT_CONFIGURED`。登録後に同じ資料の再送で成功。キー変更にFunctionsの再デプロイは不要。
5. iOS署名なし：Auth Keychain entitlementエラー。ローカル署名とビルド生成物のFinder属性除去で解消。

## まだ実施していない確認

- UIの全写真/PDFピッカー操作からの手動通し確認、マイクによる実録音。今回のiOS自動テストは実保存・送信サービスを呼び、UIをタップしていない。
- 実機の15分以上の録音、画面ロック、バックグラウンド、着信、強制終了、実際の圏外→復旧。
- 端末の実際の再起動・強制終了中アップロード。保存層の再構築とHTTP中断の検証は実施済み。
- Groqの429/5xxや長期停止、Cloud Tasksのlease期限切れ、Schedulerの周期実行による復旧を障害注入で確認すること。
- quotaの上限到達、50ページ超・暗号化・破損PDF、読み取り困難な資料など。単体テストだけで全実通信ケースを保証しない。
- 実機Debug署名にはDev Bundle IDと `group.jp.forta.Aogaku.dev` のApple開発用設定が必要。今回Apple Developerの設定は変更していない。

## 再実行と成果物

```sh
cd /Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku
python3 scripts/firebase_dev.py check
python3 scripts/test_firebase_config_safety.py
node --test scripts/test_dev_cloud_safety.cjs
npm --prefix functions test
```

Dev実E2Eは `node scripts/dev_e2e.cjs core|pdf|audio|audio-long|races|permissions`。一度に1プロセスだけ実行する。CLI認証を使用するため、このMacでは必要に応じ `FIREBASE_TOOLS_LIB=/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib` を指定する。`core` はメモ・写真・PDFと権限・遅延削除。`audio-long` は17分の生成済み音声が必要。

Simulatorの実サービスE2E：`python3 scripts/prepare_dev_ios_e2e.py` 後、Scheme **Aogaku-AI-Dev-E2E** の `AIInputDevIntegrationTests` をDebugで実行する。通常の `Aogaku-Dev` ではこのテストを自動実行しない。テスト用パスワードはGit除外の `AogakuTests/DevFixtures/dev-e2e-credentials.json` にだけ配置。最終テストコマンドと結果は `/Users/shum/Documents/Codex/2026-10-06/y/work/dev-ios-e2e.log`。

- APIの詳細記録：`scripts/output-dev/e2e-results.json`（Git除外、token/passwordなし）。初回PDF失敗を履歴に残し、再送成功を記録。
- 認証・受付の継続状態：`scripts/output-dev/e2e-state.json`（Git除外、mode 0600。共有しない）。
- ローカル検証：domain 10件、環境分離9件、Dev API安全ガード5件すべて成功。
- Devにはテスト専用ユーザー3名・架空の1授業・本人/同授業メンバーのmembership・テスト資料が残る。本番データのコピーはない。

## 今回追加・変更したファイル

| ファイル | 理由 |
|---|---|
| `.gitignore` | Dev環境設定、E2E認証状態、テストfixtureを除外 |
| `Aogaku.xcodeproj/project.pbxproj` | Debugだけ任意config読み取りに対応し、Dev entitlementsを使用 |
| `Config/Aogaku-Debug.entitlements`, `Config/Extensions-Debug.entitlements` | Dev App Groupの分離 |
| `Aogaku/AIInput/AppBackend.swift` | Debug接続先のDev固定を追加 |
| `Aogaku/AIInput/SourceIngestionService.swift` | 他環境の署名upload URLを拒否 |
| `Aogaku/timetable.swift`, `AogakuWidgets/AogakuWidgets.swift`, `AogakuAction/ActionViewController.swift`, `shared/WidgetShared.swift` | Debug共有領域を統一し、本番と分離 |
| `functions/src/ai/index.ts` | 専用実行SA、同じprojectのtask URI、音声だけADCでGroq Secretを取得 |
| `functions/src/ai/extractors.ts` | PDF.js 6終了処理・日本語CMap・旧PDF checkpointの修正 |
| `scripts/firebase_dev.py`, `scripts/check_firebase_deploy_target.py` | 承認済みID・project number・bucket固定と安全な限定再デプロイ |
| `scripts/dev_cloud.cjs`, `scripts/provision_dev.cjs` | Dev固定のAPI/IAM管理。秘密値の読み取りは禁止 |
| `scripts/dev_e2e.cjs`, `scripts/dev_e2e_assets.swift` | 架空資料生成と実API E2E、権限・削除・中断・長音声の検証 |
| `scripts/prepare_dev_ios_e2e.py`, `AogakuTests/AIInputDevIntegrationTests.swift`, `Aogaku-AI-Dev-E2E.xcscheme` | opt-inでSimulatorの実サービスから4種類を検証 |
| `scripts/test_firebase_config_safety.py`, `scripts/test_dev_cloud_safety.cjs` | 環境・通信先ガードの回帰検証 |
| `docs/ai-input/DEV_CONNECTION_AND_RESULTS.md`, `SIMULATOR_AND_DEVELOPMENT.md`, `E2E_CHECKLIST.md`, `FILE_CHANGES.md`, `README.md` | 実施結果と現在の接続方法を反映 |

配置のみ（Git除外）：Dev plist、Dev manifest、Functions `.env.forta-aogaku-dev`、テストfixtureと実行記録。`functions/lib` と `functions/node_modules` は生成物で、ソース変更と分けて扱う。今回新たにstageしていない。全体の変更一覧は `FILE_CHANGES.md` とGit statusを参照。

最終Git集計（stagedとunstagedに同一ファイルの重複あり）：ソースstaged 25、ソースunstaged 17、新規ソース 25、既存tracked生成物の差分 221。

# AI入力：Simulatorと開発Firebaseの準備

**現在のDev接続結果は [DEV_CONNECTION_AND_RESULTS.md](DEV_CONNECTION_AND_RESULTS.md) を参照。** `forta-aogaku-dev` の実設定とAPI接続は完了し、以下の「設定がまだない」説明は初回準備時点のもの。通常は `Aogaku-Dev` / Debugを使用する。Groq Secretは音声処理時だけADC/IAMで取得する。

確認日：2026-10-06。作業コピーは `/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku`。ブランチ `codex/ai-input-foundation`、HEAD `47d54c8c03247c9311acc0c3d7bcdd2f5046a997`。commit・push・PR・mergeは行っていない。本番 `Forta-Aogaku` / `forta-aogaku` へのアクセスも、既存 `Aogaku-clean` の変更も行っていない。

## すぐにSimulatorで開く

1. `/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku/Aogaku.xcodeproj` をXcodeで開く。workspaceを別途開く必要はない。
2. Scheme **Aogaku-AI-Local**、Runの構成 **Debug**、実行先 **iPhone 17 / iOS 26.0** を選びRun。
3. `青山ハック Dev` の「AI入力画面を開く」→「AIハック」→「第N回授業」。＋メニューから写真・PDF・資料メモ、上部のマイクから録音、資料ボタンから一覧へ進める。
4. 写真は「写真から選ぶ」。Simulatorにはカメラがないため「撮影」の実動作は実機で確認する。
5. 最初の画面で「写真・PDFの確認用サンプルを作成」を押すと、架空の資料をDocuments/AIInputSamplesに生成する。PDFはFilesの「このiPhone内 → 青山ハック Dev → AIInputSamples」から選択する。写真はSimulatorのPhotosに取り込んで選択する。このSimulatorには今回生成した画像を追加済み。
6. 「資料一覧・状態サンプル」で未送信・送信待ち・送信中・解析中・利用可能・一部利用可能・失敗を表示する。`【表示サンプル】` は表示確認用。入口を開き直すと状態サンプルだけを初期状態へ戻す。共有と再送の操作は端末内の状態だけを変更する。実際のOCRや共有権限判定の成功を意味しない。

Firebase SDKの初期化・広告・外部APIを起動せず、既存の授業入力画面と端末保存を使う。実入力の資料はローカルに残り、クラウドへ自動送信されない。抽出本文を開く操作は外部接続が必要というエラーになる。ローカル確認UIDは開発AuthのUIDと別で、確認資料を開発ユーザーへ自動移行しない。

今回のDebugビルドはSimulatorで成功し、インストール・起動、実画面への導線、メモ保存と再起動復元、写真ピッカーと添付を確認した。PDFはシステム選択画面で確認用ファイルの表示まで確認。短時間録音の実ファイル生成、PDF選択完了、クラウド共有・抽出は未検証。細かい確認結果はE2E_CHECKLISTを参照。

## 環境分離の構造

| 構成 / Scheme | 接続先 | Bundle ID | 挙動 |
|---|---|---|---|
| Debug / Aogaku-AI-Local | なし | com.forta2k25.Aogaku.dev | 確認用入口、端末内だけ |
| Debug / Aogaku-Dev | 承認済みDevのみ | com.forta2k25.Aogaku.dev | 設定一致後に通常アプリとDev Authを起動 |
| Debug / 既存Aogaku | 既定はなし | com.forta2k25.Aogaku.dev | env未指定でも本番へ接続しない |
| Release / 既存Aogaku | Productionのみ | com.forta2k25.Aogaku | 今回は起動・接続・配布を行わない |

Runに `AOGAKU_BACKEND=development` があるときだけDebugがDevを選ぶ。それ以外は通信なし。Profile/Archiveは既存同様Releaseなので、今回のUI確認ではRun / Debugだけを使う。

`prepare_firebase_config.py` がビルド時に環境を確認し、roleを明示したplistと `FirebaseEnvironment.plist` を成果物へ入れる。DebugにDevファイルがなくてもローカルUIのビルドは成功するが、Devモードの起動は止まる。Devファイルが本番ID・承認ID不一致・Bundle ID不一致ならビルドを止める。起動時にもrole/project/bundleを再照合する。古い成果物のFirebase plistも取り除く。Debug専用Info.plistはFilesからの資料選択を有効にし、Analytics収集を無効化し、AdMobは公式テスト用App IDを使う（ローカルモードでは広告SDK自体を起動しない）。ReleaseのFiles公開は追加しない。元の本番plistはDebugの自動リソースコピーから除外している。

Releaseは元のローカル本番plist、または同じproject IDの `Config/Firebase/Production/GoogleService-Info.plist` を選ぶ。新しい本番設定値や秘密鍵をコードへ追加していない。Releaseのビルド・認証・通知・配布の回帰確認は統合前に別途必要。Debugは別アプリとしてインストールされるが、既存App Groupやキーチェーンの全面分離は今回の対象外なので、実機で本番と併用する前に共有領域も確認する。

## あなたがConsoleで作成するもの

以下はまだ作成・変更していない。**新しいDevプロジェクトを選んでいることを画面上で確認してから**行う。

1. Firebase Consoleで新規プロジェクトを作成。表示名の例は `Forta-Aogaku-Dev`。実際のproject IDは世界で一意のものを採用し、表示名とは区別する。本番のコピー・本番データのインポートは不要。
2. Cloud FunctionsなどのためDevをBlazeへ設定し、予算通知を設定。予算通知は課金の強制停止ではない。
3. iOSアプリを登録。Bundle IDは **com.forta2k25.Aogaku.dev**。Dev用 `GoogleService-Info.plist` をダウンロードする。
4. Authenticationで必要なログイン方式を有効化。初期E2Eはアプリ既存のメール/パスワード方式でテストユーザーA/B/Cを新規作成する。本番ユーザーは移さない。Googleログインも使う場合はDev専用Google OAuth設定・新しいREVERSED_CLIENT_IDのURL Scheme対応を別途行う。Debug専用Config/Info-Debug.plistには本番Googleコールバックを入れていない。Dev plist受領後にDevのREVERSED_CLIENT_IDを登録してから使用する。AppleログインはDev App ID/entitlementsをApple側でも用意する。
5. Firestore **Standard / Native mode、(default)** を作成。Storageの既定バケットを作成。安全なルールから開始する。配置はFunctionsの固定リージョン **asia-northeast1** に合わせた東京が候補。Storage finalizeトリガーとバケット配置の互換性を確認し、作成後変更できない配置は選択前に確認する。
6. 次のAPI/サービスをDev Google Cloudプロジェクトで有効化。実際のIAM・デプロイは、ファイル受領後にDevだけを対象として別段階で実施する。

## 渡してほしい設定・ファイル

- Devの **project ID / project number / 表示名**。
- Dev iOSアプリの **GoogleService-Info.plist**。チャットへ内容を貼らず、ファイルを指定フォルダへ置くか添付する。
- **Storageバケット名**、FirestoreとStorageのロケーション、有効にしたAuth方式。
- Blaze/APIの設定完了状況。テストユーザーのUIDは後で必要だが、パスワードは渡さない。

配置先：

```text
Config/Firebase/Development/GoogleService-Info.plist
Config/firebase-development.json
```

後者は `Config/firebase-development.example.json` をコピーし、`projectId` を実際のDev IDへ変更する。両ファイルはGitから除外済み。サービスアカウントのJSON秘密鍵、Groqキー、Firebase CLIトークン、本番設定ファイルは渡す必要がない。FirebaseのiOS plistはアプリ設定であり、サーバー秘密鍵とは別物。

## 開発側だけに接続する手順（今は未実行）

作業コピーのルートで、まず **ネットワークを使わない** 検査をする。

```sh
python3 scripts/firebase_dev.py check
```

現在はDev設定がないのでSTOPになる。`.firebaserc` は空で、自動選択の本番defaultを取り除いた。aliasを後で使う場合もDevだけを登録し、ラッパーはaliasに依存せず検査済みの実project IDを `--project` へ必ず渡す。

その後、Devへの接続・デプロイ指示を受けてから、認証済みFirebase CLIで以下を使う。現時点では実行していない。

```sh
python3 scripts/firebase_dev.py secret
python3 scripts/firebase_dev.py deploy
```

secretは `GROQ_API_KEY` をFirebase CLIの対話入力からSecret Managerへ登録する。deployはAI関数12個とDevのFirestore Rules/indexes・Storage Rulesだけを対象にする。通常firebase.jsonにもFunctions/Firestore/Storageのpredeploy照合を追加した。これらのガードはこの設定とラッパーを使用する操作に限られ、Consoleや別のconfigを使う操作をシステム全体で禁止するものではない。汎用CLIでの操作は行わない。

Storageライフサイクル設定は `storage.lifecycle.json` をDevバケットだけへ適用する追加操作が必要。ラッパーdeployには含めていない。soft delete/versioningによる保持と料金も確認する。新しいDevには既存の時間割・授業データがないため、テスト授業を少量作成する。共有検証には共通の `classes/{id}` と管理者が検証したmembershipが必要で、利用者が時間割へ追加しただけでは共有できない。

## 必須サービス・API・有効化方法・費用

Firebase ConsoleでAuth/Firestore/Storageを作成し、Google Cloud Consoleの **Devプロジェクト → APIとサービス → ライブラリ** で対応APIを有効化する。Functionsの初回deployが管理基盤APIを有効化することもあるが、本番に対して実行してはいけない。

| サービス / API | この実装の用途 | 有効化・作成 | 課金が発生し得る対象 |
|---|---|---|---|
| Firebase Authentication / identitytoolkit.googleapis.com | Callableのrequest.auth、ユーザー分離 | Firebase Auth開始・provider有効化 | provider/プラン依存。電話認証は今回不要 |
| Firestore / firestore.googleapis.com | 受付、状態、本文chunk、membership、利用枠 | Firebaseで(default) DB | 読み書き、保存、index、通信 |
| Storage / storage.googleapis.com | 原本、抽出物、checkpoint、署名PUT | Firebaseで既定bucket | 保存、操作、通信、保持世代 |
| Cloud Functions / cloudfunctions.googleapis.com | Callable、worker、復旧・削除処理 | DevでAPI有効化、Functions v2 deploy | CPU/メモリ、実行時間、通信 |
| Cloud Run / run.googleapis.com | Functions v2の実行基盤 | API有効化 | 上記実行基盤の費用 |
| Cloud Tasks / cloudtasks.googleapis.com | aiProcessSourceキュー、再配信 | API有効化。task functionのdeployでキュー作成 | 操作数、実行先の処理 |
| Cloud Scheduler / cloudscheduler.googleapis.com | aiReconcileInputsを15分周期で実行 | API有効化。schedule function deployでjob作成 | job、呼び出し先の処理 |
| Secret Manager / secretmanager.googleapis.com | GROQ_API_KEY | API有効化、CLI対話登録 | secretバージョン・アクセス |
| Cloud Vision / vision.googleapis.com | 写真OCR、PDFのOCRが必要なページ | API有効化、ADC認証 | OCR画像/ページ数 |
| IAM Credentials / iamcredentials.googleapis.com | 署名URLのsignBlob | API有効化、署名主体の権限設定 | 利用枠/関連処理。API単体の料金は最新料金を確認 |
| Eventarc / eventarc.googleapis.com | aiRejectLateUploadのStorage finalize | API有効化、trigger deploy | イベント配送 |
| Pub/Sub / pubsub.googleapis.com | Storage/Eventarc配送基盤 | API有効化、Google管理SA設定 | メッセージ配送等 |
| Cloud Build / cloudbuild.googleapis.com | Functionsのbuild | API有効化、CLI deploy | build時間 |
| Artifact Registry / artifactregistry.googleapis.com | buildされたコンテナ保存 | API有効化、deploy時repository | 保存・通信。cleanup policy確認 |
| Cloud Logging / logging.googleapis.com | 障害・処理追跡 | 通常自動、ログ確認 | 保存量・保持期間 |

5つの主要サービス（Auth/Firestore/Storage/Functions/Tasks）はすべて必要。既存アプリ全体でRemote ConfigのフェッチやFirestoreへのanalytics_events書き込みもあるが、Devモードでは同じDev設定を使用する。AI入力自体にRealtime Database、Firebase AI Logic、Vertex AI、OpenAIキー、埋め込みDB、APNsは不要。全文検索は現在lexical-ja-v1で、AI回答生成UIは未実装。

有料サービスに無料枠があっても費用ゼロは保証しない。workerは2GiB・最大30分・maxInstances 3。Visionページ数とGroq音声秒数、失敗再試行、Scheduler、原本保持をDevで計測する。価格は [Firebase料金](https://firebase.google.com/pricing)、[Vision料金](https://cloud.google.com/vision/pricing)、[Groq音声モデル料金](https://console.groq.com/docs/speech-to-text) で実行前に確認する。

## IAM：誰に何を付けるか

IAMはDevだけに設定する。第2世代の既定実行SAは一般にComputeのSAで、App Engine SAとは限らない。実際にデプロイされたfunctionのserviceAccountを確認してから付与する。専用実行SAを採用する場合はFunctionsのserviceAccount指定も合わせる。今回はクラウドIAMを未確認・未変更。

| 主体・対象 | 必要な権限 / ロール候補 | 理由 |
|---|---|---|
| Callable/worker/reconcileの実行SA → Dev DB | roles/datastore.user | Admin SDKによる読書き（Rulesだけでは許可されない） |
| 実行SA → Devの既定bucket | roles/storage.objectAdmin | 原本/抽出物の取得、保存、列挙、削除 |
| Vision呼出SA → Dev project | roles/serviceusage.serviceUsageConsumer | 有効化済みAPIの利用。ADCを使用 |
| enqueueするSA → aiProcessSource queue | roles/cloudtasks.enqueuer | tasks.create |
| enqueueするSA → タスクで使うOIDC SA | roles/iam.serviceAccountUser | serviceAccounts.actAs |
| タスクOIDC SA → aiProcessSourceの実行先 | roles/run.invoker（v2）など実行先に対応するinvoke権限 | 401/403を防ぐ。Firebase Tasksのcloudfunctions.invoker要件も実際の作成先で確認 |
| 署名URL発行SA → 署名するSA（通常自身） | roles/iam.serviceAccountTokenCreator、またはsignBlobだけのカスタムロール | 署名PUT URL生成。project全体へのToken Creator付与は避ける |
| worker実行SA → GROQ_API_KEY secret | roles/secretmanager.secretAccessor | defineSecretをworkerにバインド（CLIが設定する範囲を確認） |
| Storageサービスエージェント、Eventarc trigger SA | Pub/Sub Publisher / Eventarc Event Receiver / 実行先Invoker等 | Storageイベント配送。Google管理SAとruntime SAを混同しない |
| 設定担当の人 → Dev project | Service Usage Admin等 | API有効化、必要なIAM設定。IAM変更権限は設定担当だけ |
| deploy担当 → Dev project/SA | Cloud Functions Developer相当 + runtime/build SAのService Account User、必要に応じScheduler/Tasks/Eventarcの管理、Secret作成、Rules/index管理権限 | 初回deployで作るリソースに必要な権限をエラーと公式要件に合わせて付与 |

最後のdeploy権限は組織ポリシー・build SA・初回作成状況で変わる。全ロールを一律にOwner/Editorへまとめず、対象DevとSA/queue/bucket/secretへ絞る。通常Google管理サービスエージェントの権限はサービス有効化・deploy時に作成される。人のユーザーへサービスエージェント専用ロールを付けない。

根拠： [第2世代のSA](https://firebase.google.com/docs/functions/2nd-gen-upgrade)、[Tasksの権限とキュー](https://firebase.google.com/docs/functions/task-functions)、[Cloud Runのサービス認証](https://cloud.google.com/run/docs/authenticating/service-to-service)、[署名のsignBlob](https://cloud.google.com/storage/docs/authentication/creating-signatures)、[Eventarc Storage trigger](https://cloud.google.com/eventarc/docs/run/create-trigger-storage-gcloud)。

## Vision/Groqのためにあなたが用意するものだけ

| 用意するもの | 安全な登録方法 |
|---|---|
| DevのVision API有効化、課金、実行SAのAPI利用/Storageアクセス | Dev Google Cloud Console。実行時ADCなのでVision API keyやJSON秘密鍵は不要 |
| Groqアカウントの開発用API key、対応モデルの利用枠 | キーをチャットやGitへ貼らず、上記secretラッパーの対話入力で登録 |
| DevのGROQ_API_KEY Secret | workerがdefineSecretで参照。他の関数やiOSへ配らない |
| DevのTasks/Scheduler/署名URLのIAM設定を行う担当者 | Devだけの権限設定。実際のqueue/SAはdeploy後に確認 |
| 許可された小さな写真・テキストPDF・スキャンPDF・短い日本語音声 | テスト資料だけをDevとGroqへ送る。実ユーザー資料を使わない |

サーバーは `whisper-large-v3-turbo`、低信頼時に `whisper-large-v3` を使う。言語はja、verbose_jsonのsegment時刻を保存する。通常の環境変数にAPI keyを書かず、必要なユーザー定義Secretは現実装では **GROQ_API_KEYのみ**。project/bucket認証はFirebase Adminの実行環境から取得し、独自の本番キーを追加しない。Functions Node.js22、リージョンasia-northeast1はソース側で指定済み。

根拠： [VisionのADC](https://docs.cloud.google.com/vision/docs/authentication)、[Firebase Secrets](https://firebase.google.com/docs/functions/config-env)、[Groq Speech-to-Text](https://console.groq.com/docs/speech-to-text)、[Scheduler](https://firebase.google.com/docs/functions/schedule-functions)。

Debug用AdMobサンプルIDの出典：[Google公式セットアップ手順](https://developers.google.com/admob/ios/quick-start)。

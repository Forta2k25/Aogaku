# AI入力の確認項目とE2E計画

2026-10-06。✓はこの作業で実行確認済み、□は実施待ち。ソースに実装済みでも、クラウド実通信・実機検証済みとは扱わない。開発Firebaseの接続・デプロイはまだ行っていない。

## 1. Firebase / 外部APIなしで確認可能

使用SchemeはAogaku-AI-Local / Debug。Cloud成功の代替として表示サンプルを使う場合は、それがサンプルであることを明示する。

- [x] Simulator向けアプリ全体Debugビルド、独立したDevアプリのインストール・起動。
- [x] 初期入口 → 実際の授業画面 → AIハック → 第N回授業 → ＋メニュー。
- [x] メモ入力 → 資料保存 → 一覧の「送信待ち / 自分のみ」。終了・再起動後にも復元。
- [x] Photosピッカー → 架空画像の選択 → 添付表示 → 送信操作 → 一覧の「送信待ち / 自分のみ」。
- [x] PDF追加のシステム選択画面を開く。
- [ ] Files → このiPhone内 → 青山ハック Dev → AIInputSamples → sample-document.pdfを選択 → 添付 → 送信待ち → プレビュー。Files内の確認用フォルダ・PDFファイル表示まで確認したが、自動操作で選択を完了できず、取り込み完了は手動確認が必要。
- [x] 録音開始ボタン、カメラボタンを表示する。カメラ撮影はSimulatorでは不可。
- [ ] Simulatorのマイク許可、短時間録音 → 停止 → 音声ファイル → ローカル再生 → 再起動復元。Macの音声入力に依存し、実機長時間テストを代替しない。
- [ ] 状態サンプルの未送信 / 送信待ち / 送信中 / 解析中 / 利用可能 / 一部利用可能 / 失敗を表示。
- [ ] 失敗サンプルの「再試行」→ ローカル送信待ち。実際のネットワーク再送は行わない。
- [x] 実資料の削除メニューを表示（削除実行はしていない）。
- [x] 表示サンプルの「この授業に共有」→「自分のみに戻す」の表示・ローカル状態変化。権限テストではない。
- [x] 端末保存の単体検証：受付ID維持、再起動、破損時復旧、UID分離、会話編集で資料保持、削除意図の永続化、ファイル削除。
- [x] 設定検査：Dev一致のみ受理、本番/不一致を拒否、Debugに本番plistを入れない。
- [ ] 接続中の強制終了、送信中削除などの競合はこのモードでは再現しない。

## 2. 開発Firebase接続後に確認可能（Vision/Groqなし）

- [ ] Dev AuthのA/B/Cでログイン、ログアウト、アカウント切替。ローカル確認UIDの資料は別利用者へ表示されない。
- [ ] 写真/PDF/音声の受付、署名URL発行、PUT、完了受付、ジョブ投入、状態取得。抽出の成功までは要求しない。
- [ ] メモ → ローカル保存 → aiCreateSource → Tasks worker → 本文/chunk → ready → 資料一覧 → aiGetEvidence → aiRetrieveContext。メモ処理自体にはVision/Groq通信不要。ただしworkerのdefineSecret設定はデプロイに必要。
- [ ] 再送、期限切れPUT URLの再取得、同じclientRequestIdでの再開。
- [ ] Firestore indexes、Rules、Storage RulesがDevで有効。aiパスはクライアント直接書込不可。
- [ ] 認証・所属、共有/撤回、他授業拒否、削除/遅延upload削除、reconcile回収。
- [ ] signed PUTでContent-Type/サイズ/世代の不一致、AuthなしCallable拒否。

## 3. Vision/Groq接続後に確認可能

- [ ] 写真OCR：日本語、回転、薄い文字、解像度、読めない画像。本文・文字位置と欠落を確認。
- [ ] PDF：テキストPDF、スキャンPDF、混在PDFのページ単位処理、pageNumber/文字位置、部分失敗、パスワード/上限超過の拒否。
- [ ] Groq：短音声、日本語用語、無音、15分境界を跨ぐ音声、時間位置、重複除去、低信頼フラグ、TurboからV3への再試行。
- [ ] 429/5xx/タイムアウト、途中1ページ/1音声分割失敗、partial_ready→再試行でcheckpoint利用。
- [ ] chunk本文の検索と出典取得。画像の図表理解やAI回答生成は現実装の対象外。
- [ ] 処理時間、Visionページ数、Groq秒数、Tasks再配信、料金を記録。

## 4. 実機で確認すべきもの

- [ ] カメラ撮影、写真権限、Files外部providerからのPDF、マイク許可拒否・後から許可。
- [ ] 16分/30分/90分近い録音。1録音上限と週180分上限、メーター、端末温度・電池・容量。
- [ ] 録音中の画面ロック/バックグラウンド/電話着信/Siri/音声経路切替/Bluetooth。
- [ ] 録音中の強制終了・OS終了・再起動：保存できた範囲の復旧と録音中断表示。失われた部分を録音済みと表示しない。
- [ ] 圏外→Wi-Fi/モバイル回線復帰、回線切替、アップロード途中の強制終了。
- [ ] Dev provisioning、App Group、Live Activity/extension、キーチェーンの本番アプリとの分離。Simulatorの無署名ビルドは実機署名の証明ではない。

## E2E実施前の条件

Dev設定検査、Blaze/API/IAM、GROQ_API_KEY、AI関数12個/Rules/indexのDev deployが完了していること。Aogaku-Dev / Debugで接続先IDを確認してから始める。実行の承認前に本番やDevへデプロイしない。

使用するのは架空または利用許可された資料とDev専用A/B/C。AとBは共通classDocId・同年度/学期の検証済みmembershipを管理側から付与、Cは別授業。所属自動付与は未接続なので管理側のfixtureが必要。手入力授業（classDocIdなし）は所有者別の授業IDになるため、そのままではA/B共有テストにならない。

記録する値：run ID、Dev project ID、UID、clientRequestId、sourceId、courseOfferingId、lectureId、sourceVersion/activeVersion、状態、coverage、chunk/locator、処理時間、料金。署名URL・Authorization・Groqキーは記録しない。検索結果が得られたこととAI文章生成の成功は分ける。現在、画面内でAI回答を生成する処理はないため、検索の最終段階はAPI利用側で実施する。

## 正常系：4種類

| ID | 手順 | 合格条件 |
|---|---|---|
| P1 写真 | 写真選択 → 添付段階で端末保存 → 送信 → aiCreateSource → signed PUT → aiCompleteSource → Tasks → Vision → 本文/chunk → 一覧 → aiRetrieveContext/aiGetEvidence | sourceIdが途中で変わらずready。既知の日本語が本文にあり、出典の資料IDと位置が対応。再起動後の添付・会話・IDも一致 |
| P2 PDF | 3ページ（埋込テキスト/スキャン/混在）を選択 → 端末保存 → upload → pdfjs/ページOCR → 出典保存 → 一覧 → 検索 | ページ数・処理済み数・欠落ページが一致。本文とpageNumber/文字位置が各原本ページに対応。OCRが不要なページも正しく抽出 |
| P3 メモ | 固有語入りテキスト → メモ保存 → 受付/Tasks → ready → 一覧/本文 → 検索 | 質問文は資料に混ざらず、保存したメモだけが本文。Vision/Groqを呼ばない。メモの文字位置と本文が対応 |
| P4 音声 | 16分以上の既知日本語音声を録音 → 停止/端末保存 → upload → 15分分割/2秒境界重複 → Groq → 時刻付き本文 → 一覧/検索 | 録音時間とstartMs/endMsが整合し、境界の既知語の欠落/重複を人が評価。原本削除/保持規約、低信頼区間、モデル選択を確認 |

音声の高負荷な90分テストは、短い正常系・料金確認後に実機で行う。PDFの図表の意味や専門語精度は、この入力基盤の保証には含めない。

## 障害・競合・権限

| ID | 操作 | 合格条件 |
|---|---|---|
| F1 通信切断 | 受付前、PUT途中、PUT完了後/完了受付前に切断し復帰 | 原本保持、再送可能、同じ受付ID、source重複なし。PUTは世代0条件で上書きしない |
| F2 再送/重複 | 同じclientRequestId/同じpayloadを同時・連続送信。次に同ID/異payload | 同じsourceIdへ収束、利用枠二重計上なし。異payloadはREQUEST_CONFLICT。Task重複でも公開runが増殖しない |
| F3 再起動/強制終了 | 下書き/送信待ち/PUT中/解析中に終了し再起動 | UID・授業・授業日・会話・添付・IDを復元。送信意図を継続し、削除意図を取り消さない |
| F4 upload中削除 | 署名URL発行済みで削除、削除後に遅延PUTも実行 | 以後取得/検索不可。遅延uploadをaiRejectLateUploadが削除し資料が復活しない |
| F5 解析中削除 | OCR/ASR中・chunk書込直前に削除、Tasksを再配信 | run公開不可、抽出物/原本清掃、deletedを上書きしない。reconcileでも復活しない |
| F6 共有/撤回 | Aが共有 → Bが一覧/本文/検索取得 → Aが撤回 → Bが同API再取得 | 共有時のみ本文を取得。撤回後は一覧/本文/検索/次ページから除外または拒否。原本は共有しない。既に取得した本文の回収は対象外 |
| F7 所属/別授業 | Bのmembership無効化、Cの他授業、翌年度/別学期から取得 | owner以外の取得不可。見かけのlocalCourseId一致だけで混ざらない |
| F8 外部API失敗 | Vision/Groqの429/5xx/1単位失敗 | retryable/partial_ready/coverageが正しい。再試行で既存checkpointを再利用、再公開時にversion対応 |
| F9 取り残し | lease失効、enqueue後の一時障害、awaiting_upload放置 | 15分reconcileで必要な再投入/期限処理。削除済み・終端状態は復活せず、再試行上限を守る |
| F10 入力上限 | 10MiB超画像、20MiB/50ページ超PDF、暗号PDF、100MiB/90分超音声、空/超長メモ | 意図した拒否。ローカルファイルが勝手に失われず、原本/usage/失敗状態が整合 |
| F11 署名/Rules | Authなし、別UID、直接aiパス書込、MIME/サイズ不一致、同じ原本再PUT | アクセス拒否/UPLOAD_MISMATCH/世代不一致。サービスSAのAdmin権限とクライアントRulesを区別 |

共有撤回中にAI出力側が回答生成している場合は、回答を返す直前にaiRetrieveContext等で再度権限を確認する。この出力側の連携は今回未実装。

## ローカル検証を再実行する場合

```sh
python3 scripts/test_firebase_config_safety.py
npm test --prefix functions
xcrun swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -target arm64-apple-macosx26.0 -module-cache-path /tmp/aogaku-ai-swift-cache-20261006 Aogaku/AIInput/SourceModels.swift Aogaku/AIInput/LocalSourceStore.swift scripts/test_ai_store.swift -o /tmp/aogaku-ai-store-tests
/tmp/aogaku-ai-store-tests
```

上のSwiftコマンドはこのMac/Xcode用。別環境ではSDKパス・target・書込み可能なmodule cacheを合わせる。

Firestore/Storage Emulatorの権限検証6件は前回合格済み。再実行時はfirebase.ai-test.jsonとdemo-aogaku-inputだけを明示する。Cloud Tasks/OCR/ASRの実通信はこれらの単体テストで検証しない。
# 2026-10-06 Dev実施結果

[DEV_CONNECTION_AND_RESULTS.md](DEV_CONNECTION_AND_RESULTS.md) に現在の実証結果を記録。4入力・17分分割・Simulatorの実保存/送信サービス・共有撤回・他授業アクセス拒否・中断再送・upload中/解析中削除・遅延upload削除は成功。以下のチェックリストをすべて実施済みとは扱わず、実機のマイク録音・着信・強制終了・圏外などは残課題とする。

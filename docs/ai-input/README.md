> 2026-10-06: Phase2bはnamed database分離案へ変更。最新構成は [NAMED_DATABASE_ARCHITECTURE.md](NAMED_DATABASE_ARCHITECTURE.md) を参照。本書のdefaultへのAI Rules追加案・過去receiptは本番反映に使用しない。

# AI入力基盤（input-v1）

最新の本番反映結果: [PHASE3A_PRODUCTION_RESULT.md](PHASE3A_PRODUCTION_RESULT.md)。2026-10-07にPhase 1・2・3a完全成功。旧AI3件だけを個別更新し、他Functions/Secret/IAM/Rules等は保持。Phase 3bは追加承認待ちで未実行。

現在の対象: 最新 `origin/main` の `9d596f7` に統合した `codex/ai-input-main-integration`。元のAI実装は `47d54c8` を基点とし、`ed4e424` に保存済み。

統合・再検証の結果と現在開く作業コピーは [MAIN_INTEGRATION_RESULTS.md](MAIN_INTEGRATION_RESULTS.md) を参照。通常は統合コピーの `Aogaku.xcodeproj` をScheme `Aogaku-Dev` / Debugで開く。

現在の授業識別仕様と今回のDev検証は [COURSE_IDENTITY_AND_RESULTS.md](COURSE_IDENTITY_AND_RESULTS.md) を参照。2026-10-06に年度別IDとsnapshot対応を追加した。

## この実装でできること

授業のチャットから写真・録音を送信し、＋メニューからPDFを取り込む、入力した文章を資料メモとして保存する。質問文は資料に混ぜず、端末の会話履歴として保存する。資料は利用者・授業・年度・学期・授業日と一緒に端末に保存してから送信する。

授業の資料一覧には未送信・送信中・解析中・利用可能・一部利用可能・失敗を表示する。再起動後に同じ受付IDで再送し、失敗時に再試行できる。会話を編集しても資料は残る。資料を削除するとクラウド原本・抽出物・検索断片を削除し、遅れて完了した処理も公開できない。

写真はCloud Vision OCR、PDFはページごとの埋め込みテキスト抽出とOCR、音声は15分単位のGroq Whisper ASRを利用する。音声は境界を2秒重複させ、元の録音に対応する時刻を返す。低信頼区間はフラグを付ける。PDFの図表の意味は解釈しない。

## 構成

```text
UIKit → SourceIngestionService → LocalSourceStore（原子的な台帳とファイル）
                            → Firebase Callable（認証・受付・状態・削除）
                            → 署名付きPUT（上書き不可）
Cloud Tasks → aiProcessSource → OCR / PDF / ASR → 抽出物と検索断片
出力側 → aiRetrieveContext → 権限を確認した本文とページ・時刻・欠落情報
```

Swiftは `Aogaku/AIInput/`、サーバーは `functions/src/ai/`。`functions/src/index.ts` は既存の友だち通知を維持し、AI関数を追加exportしている。

保存先は `aiSources/{sourceId}/runs/{runId}/chunks/{chunkId}`、`aiCourseOfferings/{id}/memberships/{uid}`、`aiUsage/{uid}/periods/{period}`。これらはクライアントから直接読み書きせずCallableを通す。既存の公開 `entries` とユーザー下位コレクションの許可には依存しない。

collection名と11種類のpathは `functions/src/ai/schema.ts` に集約している。実保存schemaには `entries` はない。ただし既存Rulesはschema外の任意 `entries` 作成を許すため、全AI領域の遮断を保証できずPhase 2bは停止中。[schema監査・Emulator / Dev結果](SCHEMA_COLLISION_AUDIT.md)を参照。

## 動作確認

Node.js 22とnpm、Firebase CLI、Java 21以上、Xcodeを使用する。

```sh
npm ci --prefix functions
npm test --prefix functions
firebase emulators:exec --project demo-aogaku-input --config firebase.ai-test.json --only firestore,storage 'npm run test:emulator --prefix functions'
swiftc Aogaku/AIInput/SourceModels.swift Aogaku/AIInput/LocalSourceStore.swift scripts/test_ai_store.swift -o /tmp/aogaku-ai-store-tests
/tmp/aogaku-ai-store-tests
xcodebuild -project Aogaku.xcodeproj -scheme Aogaku -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

エミュレーターテストは実際のFirestore・Storageに対して動き、Cloud Tasksへの投入だけテスト内で置換する。OCR/ASRの外部通信は実行しない。Javaの保存場所やポートは各開発環境に合わせる。

## ローカル確認と開発用Firebase

現在の `.firebaserc` は空です。Debugは既定で通信なしの確認用アプリになり、本番のplistは同梱しません。Simulatorでは `Aogaku-AI-Local` Schemeを使います。開発用設定が未登録の場合、`Aogaku-Dev` は接続せず設定エラーを表示します。

具体的な設定・サービス・IAM・Secretの手順は [SIMULATOR_AND_DEVELOPMENT.md](SIMULATOR_AND_DEVELOPMENT.md)、確認項目とE2E計画は [E2E_CHECKLIST.md](E2E_CHECKLIST.md) にまとめています。初期のローカル準備段階ではクラウド操作を行わず、その後の明示許可でDevのみ接続・検証した。最新結果は上記の年度別授業検証記録を参照。

開発用の実際のproject IDとiOS plistを登録し、ローカル検査を通してから、利用者の指示で開発専用ラッパーを使います。汎用 `firebase deploy` や `gcloud storage` コマンドはここでは実行しません。ライフサイクル・soft delete・versioningの設定も開発バケットだけで別途確認します。

## 初期上限と保持

| 入力 | 上限 |
|---|---|
| 写真 | 10MiB、JPEG/PNG（現行iOSはJPEG） |
| PDF | 20MiB、50ページ、パスワード付き不可 |
| 録音 | 100MiB、1秒〜90分、週180分 |
| メモ | 20,000 UTF-16文字、80,000バイト |
| 受付 | 1人1日100件・500MiB |

週は日本時間の月曜始まり。サーバーは受付時に録音時間を予約し、実ファイルの時間も検査する。削除・未完了でも予約量はその週の利用量に残る。端末の従来の録音メーターとサーバーの利用量は別々で、別端末や別アカウントの利用量をメーターに同期する機能は未実装。

署名PUTは10分間有効。サイズ・MIME・オブジェクト世代を完了時に検査する。原本を上書きできない。受付失敗時でもローカルファイルを残す。署名URL発行後に完了した削除済み資料のアップロードはStorageトリガーで削除する。

失敗・部分成功の再試行は受付から24時間以内、最大6回。チェックポイントは同じSourceと処理器版の中で再利用する。Cloud Tasksは自動で最大4回再配信し、15分周期の復旧処理が失効した実行ロックと取り残された受付を回収する。全資料間の内容ハッシュによる重複排除は未実装。

## 授業共有

初期状態は本人のみ。共有するには、管理側で `aiCourseOfferings/{courseOfferingId}/memberships/{uid}` に `{"status":"verified","active":true}` を設定する。クライアントが時間割へ追加したことだけで共有権限を付与しない。検証済みの所属を登録する自動処理は別途接続する。

授業IDは年度＋5桁classDocId（例 `2026:00004`）。学期は資料snapshotと授業回に保存し、年間offering IDには含めない。年度はsyllabus URLのYRを優先し、時間割年度が次点、両方なければunresolved。docID欠損は所有者・永続localCourseUUID・年度で分離し、codeや授業名では識別しない。授業回は学期、日本時間の `dayID` と `occurrenceKey` で識別する。現行UIは1日1回の `default` を使用する。

UIの「この授業に共有」は抽出本文の `knowledgeVisibility` を変更する。原本の `rawVisibility` は本人のまま。一般公開は扱わない。権限取消・共有撤回後は新しい本文取得を拒否する。既に人が閲覧した本文や既に生成した回答を回収する機能は入力基盤に含まれない。

## 出力側との接続

詳細は [API.md](API.md)、例は `contracts/ai-input/context-response.example.json` を参照。

質問・要約・試験対策は `aiRetrieveContext` の `purpose` を使い分ける。返却本文を資料データとして扱い、そこに書かれた命令を実行しない。出典は `sourceId`、`activeVersion`、`chunkId`、`locator` で保持する。`coverage` と `truncated` が欠落や取得範囲を表す。資料が0件のときに読んだことにしない。

## この版の範囲と残る検証

- 検索は日本語の単語一致（`lexical-ja-v1`）。埋め込み・意味検索と検索品質評価は未実装。
- 画像/PDFは文字抽出。図表の解釈、専門語の補正、シラバスの自動取り込みは未実装。
- 文字起こしの原応答・低信頼フラグは残す。別のAIによる補正文はまだ作らない。
- クラウド資料一覧と抽出本文は取得できる。別端末からの原本ダウンロード、未分類の旧録音の割当て、資料の授業回変更は未実装。
- 本文取得は権限確認時点の結果。出力側で生成中に権限が変わる場合は、回答を返す直前にも同じAPIで再確認する。
- 写真OCR・スキャンPDF・Groqへの実通信、90分録音・強制終了・着信・圏外からの再送は、開発用の実機と許可された資料での確認が必要。
- UIにAI回答を生成する処理は追加していない。生成担当はコンテキスト取得APIへ接続する。

仕様上の候補値を、そのまま製品の精度保証として扱わない。まず開発用環境で4種類を通し、抽出結果・時間・料金・欠落を確認してから試験導入する。
# Dev実環境の現在の状態

2026-10-06：`forta-aogaku-dev` への接続と12 AI Functionsのデプロイを完了。写真・PDF・メモ・短音声・17分音声の実API E2E、SimulatorのiOS保存/送信サービスE2E、権限・再送・削除競合を検証した。結果・残課題・変更ファイルは [DEV_CONNECTION_AND_RESULTS.md](DEV_CONNECTION_AND_RESULTS.md)。本番、Aogaku-clean、GitHubへの操作なし。

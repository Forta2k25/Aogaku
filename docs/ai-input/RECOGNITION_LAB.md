# Recognition Lab（開発専用）

基点: `927a3d65c43ba863f94fc995aaef91e5abc0e02d`。ブランチ: `codex/ai-recognition-comparison-lab`。

## 起動

- `Aogaku-AI-Local`: AI入力ローカル確認 → Recognition Lab。Firebaseを起動しない。画像fixture、比較画面、Apple Speechを使用できる。Vision/GroqはDev接続が必要というエラーになる。
- `Aogaku-AI-Recognition-Lab`: Debug、Dev bundle `com.forta2k25.Aogaku.dev`、Dev FirebaseでLabを直接起動する。既存Dev設定ファイルが必要。Email／Password入力は不要。初回にDevの匿名認証を自動実行し、以後はFirebase Authが保存した端末セッションを再利用する。既存Devセッションがある場合は置き換えない。
- `Aogaku-AI-Dev-E2E`: 既存のScheme・起動設定を変更していない。
- 通常Aogaku／Release: Labはコンパイル対象から除外され、導線を追加しない。作業開始時の通常Schemeのユーザー変更を保持。

## 境界とarchitecture

```text
Debug UI → LabDevRecognitionProvider → recognitionLabRun (forta-aogaku-dev)
                                 ├ VisionOCR (ADC)
                                 ├ ImageInterpreter protocol → GroqImageInterpreter
                                 └ Groq ASR
Debug UI → LabAudioRecognitionProvider → AppleLabSpeechRecognizer (ja-JP)
```

バックエンドは `recognition-lab/functions`、Firebase codebase `recognition-lab`。production用functionsのimport/exportやパイプラインを変更しない。Callableはproject ID、Lab enabled flag、Firebase Auth、private Dev allowlistを全て検証。デフォルトはclosed。iOSでもDebug・Dev project/bundleを確認し、セッションがなければ自動匿名認証してから呼ぶ。外部APIのserver側Auth／UID限定許可は維持する。Apple SpeechにはFirebaseセッションは不要。

実験の保存先はメモリ／端末DocumentsのRecognitionLab JSONだけ。Firestore、Storage、Tasks、Schedulerへ書かず、aiSourcesにも保存しない。画像・音声のbytesをCallableへ渡すためsigned URLを使用しない。providerキーはDev Secret Managerの既存GROQ_API_KEYをruntimeで参照。VisionはADC。iOSにserver keyを渡さない。

比較結果の「最終evidence text」は採用候補であり、通常AI資料へ自動保存しない。保存ボタンも端末内比較JSONのみ。実資料へ採用する場合の統合は別判断とする。

## モードと結果

画像: `vision_ocr` / `vision_llm` / `vision_ocr_llm`。OCRのみはDOCUMENT_TEXT_DETECTION、AIのみは元画像、併用は同じ元画像と正確に保持したOCR文字列を渡す。previewは向きを正規化し最大1600pxへ縮小した、両recognizer共通の画像。

AIはsections、印刷文字、注記、relations（向き・ラベル・不確実性）、tables、diagrams、summary、warningsのJSONを返す。schemaを検証し、決定的に検索文へ変換する。画像内の指示は資料データとして扱い、補完や推測を禁止する。JSON不正時には生JSONとエラーを保持し、evidenceとして使わない。併用のAI失敗ではRAW OCRを残し、OCR fallbackを明示する。

音声: `apple_speech` / `groq_asr` / `apple_groq`。両方式に同じ録音ファイルを渡す。AppleとGroqの結果・時間・文字数・method/model・エラーを独立保持し、自動合成しない。Apple失敗でもGroqの結果を失わない。

共通result: rawText、normalizedText、structuredResult、method、provider、model、processingMs、warnings、error。raw structured resultと最終テキストを分離して表示する。Apple/Groqはtimestamp付きの元結果も表示。

Labの安全な比較上限は画像3MB（JPEG/PNG）、音声3MB・60秒（m4a/wav/mp3）。Groq音声はserverでffprobeによる実duration検証。AppleはAVURLAssetで検証。長時間録音の本番分割pipelineとは別であり、この上限をproductionへ適用しない。

## Provider／OS仕様

2026-10-08に[Groq公式Vision仕様](https://console.groq.com/docs/vision)を確認: `qwen/qwen3.8-27b`、chat completionsの画像data URI、JSON mode。アカウントに実際に存在するかは各AI画像実行前に`/openai/v1/models`で確認する。利用できなければLAB_VISION_MODEL_UNAVAILABLEを返し、text-onlyモデル等へ暗黙に置換しない。Groq/Gemini/OpenAI等を交換するときはImageInterpreterを実装する。

音声モデルは既存pipelineの第一候補と同じ`whisper-large-v3-turbo`、language=ja、verbose_json。Labでは比較を明確にするため自動model fallback／長時間分割を追加しない。

画像は[Groqのmodel仕様](https://console.groq.com/docs/model/qwen/qwen3.8-27b)で確認したinstruct mode（reasoning_effort=none）、出力上限3000 tokensを使用する。E2Eは外部LLM呼び出し間隔を60秒にし、token budgetによる429を避ける。429は自動retryせず結果として保持。`--resume-failed`を明示した場合だけ保存済みの失敗fixtureを再検証し、過去結果もbuild内へ退避する。

AppleはiOS 16.6以上の既存targetを維持し、`SFSpeechRecognizer(locale: ja-JP)`と`SFSpeechURLRecognitionRequest`を使用。[Apple公式API](https://developer.apple.com/documentation/speech/sfspeechrecognizer)では、[supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)を確認して端末内認識を要求する。初期設定は端末内のみ。未対応時にネットワークへ暗黙fallbackしない。UIでOFFにした場合のみAppleサービスを許可し、warningを残す。Speech権限説明はDebug plistだけに追加。権限拒否・利用不可・失敗・timeout・cancelを表示する。iOS 26限定APIへの依存は導入しない。

## Dev運用

private `Config/recognition-lab.local.json`: projectIdとDev用allowedUIDs。private `recognition-lab/functions/.env.forta-aogaku-dev`: RECOGNITION_LAB_ENABLED=true、RECOGNITION_LAB_ALLOWED_UIDS=<JSON array>。production pilot allowlistとは独立。UID／認証情報をこの文書へ書かない。

```sh
npm --prefix recognition-lab/functions ci
npm --prefix recognition-lab/functions test
python3 scripts/recognition_lab_dev.py check
python3 scripts/recognition_lab_dev.py deploy
```

wrapperはproject番号／bucket／Dev plistを照合し、recognition-lab:recognitionLabRun 1件だけを対象にする。全Functions、Rules/index、productionを選択する引数を受け付けない。既存CLI deletion／unsafe replacement guardを使用。Secret値は登録済みDevのものを使いrotationしない。

`recognition_lab_audit.cjs before|after`はDevのみのread-only snapshot／差分確認。`recognition_lab_assets.swift`は架空画像5枚を生成。`recognition_lab_e2e.cjs`はignored private credentialsとsynthetic画像・合成音声を使い、比較JSONをbuild内へ保存する。tokenはメモリのみ、ログには出さない。generated/private evidenceをGitへ追加しない。

## 評価手順

普通のスライド／注記／矢印／囲み／図＋テキストの5fixtureを用意。OCR文字精度と、AIが矢印方向・ラベル・グループ・関係を保ったかを別に評価する。fixtureの注記はスタイル付き文字で、実筆跡の精度評価ではない。実際の手書きは匿名化した自前画像で確認する。

E2E PASSはAPI通信・schema・結果保持の成功を意味する。認識精度が常に正しいという保証ではない。原画像とRAW OCRを必ず並べ、モデルのsummaryが画像に存在しない因果を足していないか手動確認する。Appleの権限・端末内モデル利用可否・認識精度は実機で別途確認する。

## ログイン入力なしで実機を登録

1. Dev Anonymousを有効にする（Devのみ）：`python3 scripts/recognition_lab_dev.py enable-anonymous`。既に有効なら変更しない。
2. 実機で `Aogaku-AI-Recognition-Lab` をRun。画面が自動匿名認証する。未登録端末には案内を表示する。
3. 「端末UIDをコピー（初回登録用）」を押し、Macのターミナルで `python3 scripts/recognition_lab_dev.py register-device` を実行して非表示入力へ貼り付ける。UIDをチャット／ソースへ書かない。
4. 登録後、実機の「Dev接続 / モデル利用可否」または比較ボタンを押す。

登録scriptは実在する匿名Devユーザーを確認し、既存UIDを保持したままLab Callableのallowlistだけをenv-only PATCHする。full installed sourceと他Dev Functionsの不変を確認してからignored private設定を更新する。mutationは自動retryしない。既存Dev Email/Passwordユーザーはこの端末登録コマンドで追加しない。

端末・Keychainセッションが変わる場合は新UIDを明示登録する。自動で全匿名ユーザーを許可したり、server側のAuth／UID gateを解除したりしない。UIDコピーは5分期限（MacとのUniversal Clipboardが有効ならそのまま貼り付け可能）。自動匿名認証に失敗してもApple Speechは利用できる。

## Estimated cost（Lab専用）

料金テーブルは `recognition-lab/functions/src/pricing.ts` の `RECOGNITION_PRICING` へ集約。provider / model / pricingUnit / inputPrice / outputPrice / currency / pricingAsOf / sourceURLを保持し、Dev結果に料金snapshotを添付する。iOSの `RecognitionPricing.swift` はsnapshotのdecode／表示を担当し、Groq/Visionの単価を複製しない。結果JSON保存時も実測usageと料金snapshotを残す。2026-10-08確認。

- Qwen: APIの `usage.prompt_tokens` / `completion_tokens` / `total_tokens` を記録。[$0.80 / $4.00 per million tokens](https://console.groq.com/docs/model/qwen/qwen3.8-27b)で入力・出力コストを計算。画像tokenizationの独自推定なし。usage欠損／不正時はN/Aで、0として扱わない。structured JSONが不正・出力途中で終了しても、返却済みusageとコストは維持する。
- Whisper Turbo: [公式仕様](https://console.groq.com/docs/speech-to-text)の$0.04/audio hour、最低10秒/requestを適用。Groq responseのdurationを優先し、未提供時はffprobeで計測した長さを使用。推定課金秒数はmax(10, duration)。公式に記載のない追加の切り上げ単位は推測せず、秒精度の推定として表示。token課金しない。Labの60秒制限は維持。
- [Vision DOCUMENT_TEXT_DETECTION](https://cloud.google.com/vision/pricing): 月間1,000unitsまで無料、1,001–5,000,000は$1.50/1,000units、それ以上は$0.60/1,000units。月間利用量をこのstateless Labから取得できないため、1画像1unit、標準有料tierの$0.0015を表示。無料枠／数量割引未反映・実額は0の場合もある旨を明示。OCR+AI合計も同じ前提。
- Apple: External API cost N/A。存在しない従量料金を算出しない。

UIにEstimated cost、Pricing as of、usage、入力／出力／OCR／合計、処理時間を表示。エラーやusage欠損で金額不明の項目がある場合、全体合計はN/A、分かる分だけKnown subtotalとして表示する。USDのみで、円換算／FX固定値を導入しない。実際の請求額ではなく、税・無料枠・割引・Functions等の費用は含まない。過去のusageなしJSONも引き続きdecode可能。

`npm --prefix recognition-lab/functions test` に計算・異常usage・最低課金時間・Provider response伝搬・失敗時のusage保持テストを追加。XCTestは料金JSONの互換性と表示合計を検証する。`recognition_lab_pricing_e2e.cjs before|after|e2e`はfresh Dev baseline／単独Lab更新audit／架空の画像・音声で実測料金を確認。private evidenceはbuild内だけに保存。

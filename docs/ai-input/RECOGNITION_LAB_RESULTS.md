# Recognition Lab 実装・検証結果

2026-10-08。基点HEAD `927a3d65c43ba863f94fc995aaef91e5abc0e02d`、branch `codex/ai-recognition-comparison-lab`。以下の各実装セクションは、その時点の検証記録。Git保存前の最終確認は末尾に記載。

architectureと操作方法は [RECOGNITION_LAB.md](RECOGNITION_LAB.md)。Debug専用画面、独立Dev codebase `recognition-lab`、Callable `recognitionLabRun` 1件。画像3モード・音声3モードを実装。AppleとGroqの結果は独立保持し、比較実行ではクラウドAI資料を作成しない。

|対象|結果|
|---|---|
|Simulator Debug build|PASS|
|Local → Recognition Lab導線、矢印preview、画像3モードUI|Simulatorで確認PASS|
|Lab TypeScript build + domain/provider tests|14/14 PASS|
|Simulator XCTest: Speech権限拒否、同時実行防止、Apple失敗時のGroq保持|3/3 PASS（外部通信なし）|
|Swift結果モデル: Codable、独立保持、文字数、失敗、mode|PASS|
|Release定義なしでLab Swift moduleコンパイル|PASS（Debugコード非包含）|
|既存Functions TypeScript build + domain tests|13/13 PASS|
|Phase 5a + revision + read-only retry guards|14/14 PASS|
|Phase 4 worker Function限定IAM／Run IAM保持のstateless tests|2/2 PASS|
|Firebase設定分離|9/9 PASS|
|Lab Dev target／Debug境界／production source不変／private Git除外|4/4 PASS|
|Dev匿名拒否|PASS|
|Dev画像5fixture × OCR / AI / OCR+AI|15/15 PASS（初回＋失敗ケース明示再検証の集計）|
|Dev Groq合成日本語音声・timestamp|PASS|
|Dev既存16 Functionsのmetadata|不変PASS。Lab追加後17件|
|Dev Rules / indexes / bucket / Secret versions|不変PASS|

画像モデルはGroq `qwen/qwen3.8-27b`、音声は `whisper-large-v3-turbo`。現アカウントのmodels APIで両方を確認し実通信も成功。Appleは `SFSpeechRecognizer` / `SFSpeechURLRecognitionRequest`、ja-JP。実機の実音声認識・権限ダイアログは未検証。Apple+Groq両recognizerが実音声で成功するE2Eも残る。

初回にはモデルJSON形式の失敗と実際のGroq 429があった。schema指示を強化し、不正な生JSONも保持。instruct mode／出力3000 tokensへ変更し、独立比較を60秒間隔で実行した。provider失敗を自動retryせず、明示的な `--resume-failed` で8失敗ケースを再検証。初回結果はprivate build内へ退避し、成功済み比較を消していない。最終集計は17 checksすべてPASS。

## 品質所見と残条件

架空の矢印図のOCRは「親／遺伝／子」の文字列のみ。OCR+AIは親→子の矢印と「遺伝」ラベルの関係を検索可能な文章として保持した。一方AI単独の説明には上下の矢印方向の取り違えがあった。API/schema PASSを認識精度の完全性と解釈しない。原画像照合が必要で、実手書き・複雑な図表の評価は残る。注記fixtureはスタイル付き文字で、実筆跡ではない。

追加実行した広範なPhase 4/5a rollout testsは32/48 PASS。16件はこの作業コピーにないproduction-endpoints、production-functions、Phase 4 execution journals等に依存して失敗。production safety Python suiteも7/12 PASS、4 error + 1 failureはprivate artifact欠損。テストやproduction guardは変更しておらず、全件PASSとは報告しない。必要なprivate artifactを揃えた再実行は残条件。今回の独立Phase 5a／設定分離／Lab safety testsは上表のとおりPASS。

## 環境境界

本番forta-aogakuへのアクセス／mutation／deployなし。本番Functions source、Rules、indexes、config、client plistは変更なし。Phase 5b、sharing ON、Scheduler resume、main/PR merge、App Store公開、GitHub pushは未実施。Aogaku-clean未変更。

DevだけにCallableを作成しLab sourceを更新した。Firebase CLIがDev runtime SAの既存GROQ_API_KEY Secret Accessorを確保。Secret payloadのローカル取得・表示、Secret version/rotationは行っていない。Dev DB/Storageへの資料書き込みなし。結果は端末またはignored build内のみ。

private Dev plist／manifest、Lab allowlist／.env、Dev login fixtureと比較JSONはignored/untracked、0600（evidence directoryは0700）。private UIDをGit sourceへ入れていない。既存production private allowlist/configは変更なし。

既存tracked生成物 functions/lib、functions/node_modules とXcode自動整形は作業前へ復元。通常Aogaku Schemeは作業開始時からのユーザー変更をそのまま保持。

## 変更ファイル

- `Aogaku/RecognitionLab/`: Models、Service、ViewController、AppleLabSpeechRecognizer、Fixturesの5 Swiftファイル
- `Aogaku/AIInput/AIInputPreviewViewController.swift`: Localメニューへの導線
- `Aogaku/SceneDelegate.swift`: Debug専用Lab Schemeのroot
- `Config/Info-Debug.plist`: Speech権限説明
- `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Recognition-Lab.xcscheme`: Dev起動／offline XCTest
- `AogakuTests/RecognitionLabTests.swift`: Apple拒否・同時認証・独立保持テスト
- `recognition-lab/functions/`: package.json／lock、tsconfig、src/domain.ts、providers.ts、index.ts、test/domain.test.cjs、fixtures.json
- `firebase.recognition-lab.json`: 独立Dev codebase
- `scripts/recognition_lab_dev.py`: Dev限定deploy wrapper
- `scripts/recognition_lab_audit.cjs`: Dev read-only差分確認
- `scripts/recognition_lab_e2e.cjs`: private fixtureによる実通信比較／失敗再検証
- `scripts/recognition_lab_assets.swift`: 架空画像生成
- `scripts/test_recognition_lab.swift`: Swift結果モデル検証
- `scripts/test_recognition_lab_safety.py`: 環境境界・Git除外検証
- `.gitignore`: Lab生成物・private config除外
- `docs/ai-input/RECOGNITION_LAB.md`、`RECOGNITION_LAB_RESULTS.md`: 設計・検証結果

`Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku.xcscheme` の差分は既存のユーザー変更であり、本作業の変更ではない。

## 2026-10-08 ログイン入力不要化

Email/Passwordダイアログを削除。DevセッションがなければFirebaseの匿名認証を自動実行する。既存セッションは置き換えず、同時呼び出しは1回の認証にまとめる。Apple SpeechはAuth不要。server側のDev限定／Auth／UID allowlist gateは維持。

実機では初回発行UIDを明示登録する。`recognition_lab_dev.py register-device`はUIDを非表示入力し、実在する匿名Devユーザーを検証する。既存UIDを保持したLab Functionのenv-only PATCHだけを行い、full source・他Functions・Function/Run IAMの不変を確認する。UIDはignored private設定だけに保存する。

Dev Anonymous認証を有効化し、その他Auth設定不変をGET/PATCH/GETで確認。Functions deploy、productionアクセス、commit/pushなし。実機UID登録と実機Vision/Groq再実行はユーザー操作待ち。

検証：Xcode Debug build + Lab XCTest 6/6 PASS（認証の同時呼び出し・既存セッション維持・失敗後再試行を追加）、Lab TypeScript/provider/domain 14/14 PASS、安全境界Python 5/5 PASS、Dev設定scriptテスト 5/5 PASS（限定PATCH・既存設定維持・既に有効ならmutationなし・失敗時再試行なし・非匿名ユーザー拒否）。実機そのものの認証は未検証。

今回の変更：Lab Service／ViewController、Lab XCTest、安全境界テスト、Dev wrapper、新規device設定script、Lab設計・結果ドキュメント。

## 2026-10-08 Estimated cost実装

料金定義を `recognition-lab/functions/src/pricing.ts` に集約し、実測Groq usage／音声durationと料金snapshotを結果へ追加。画像input/output/total tokens、入力／出力／OCR／合計USD、Pricing as of、処理時間を表示。Groq ASRはtoken課金せず最低10秒の時間課金。OCRは月間利用量不明のため標準有料tier推定で、無料枠・割引未反映を明示。Apple外部料金はN/A。円換算なし。エラー／usage欠損を$0と扱わず、JSON解析失敗時も返却usageを保持。過去JSONも読み込み可能。

検証：Lab TypeScript build + domain/provider/pricing 22/22 PASS、Xcode Debug build + XCTest 11/11 PASS、Swiftモデル検証PASS、安全境界Python 5/5 PASS、Dev登録scriptテスト5/5 PASS。DevのrecognitionLabRun 1件だけ更新し、installed sourceとlocal artifact一致、他Dev Functions／UID allowlist／Function・Run IAM／Rules／indexes／bucket／Secret version不変を確認。productionへアクセス・変更なし、commit/pushなし。

今回の変更：backend domain.ts／providers.ts、追加pricing.ts／pricing.test.cjs、iOS RecognitionLabModels.swift／RecognitionLabViewController.swift、追加RecognitionPricing.swift、Lab XCTest、追加recognition_lab_pricing_e2e.cjs、Lab docs。private evidenceはbuild/recognition-lab-pricingへ保存し、Git対象外。

Dev実通信料金E2Eは `DEV_PRICING_E2E_PASS`（5 checks）：匿名拒否、画像3モード、Groq音声duration／推定額／timestamp。画像AI実測2035 input + 277 output = 2312 tokens、AI推定$0.002736を確認。音声duration 7.890062336秒（Groq response）、推定課金10秒、$0.000111111を確認。初回画像AI 429はusage/金額N/Aとして保持し、明示的な再検証と60秒間隔で成功。失敗記録はbuildへ退避し削除していない。


## 2026-10-08 feature branch保存前の最終確認

現在のソースで再実行した結果：

|対象|結果|
|---|---|
|Lab TypeScript build + domain/provider/pricing tests|22/22 PASS|
|既存AI TypeScript build + domain tests|13/13 PASS|
|Recognition Lab Scheme Simulator Debug build + XCTest|11/11 PASS（TestActionはoffline。テストターゲットを再ビルドして全件検出を確認）|
|Swift結果モデル・料金モデル検証|PASS|
|Phase 5a / revision / read-only retry guard tests|14/14 PASS|
|Firebase config safety tests|9/9 PASS|
|Recognition Lab safety tests|5/5 PASS|
|Dev端末登録script mock tests|5/5 PASS|

この保存作業ではDev／production Firebaseへのアクセス・設定変更・deployは行っていない。上のDev実通信結果は過去の実装時の記録であり、今回再実行していない。Apple OCR／Apple Document Recognitionは追加を中止しており未実装。

通常 `Aogaku.xcscheme` の既存Debug→Releaseローカル変更はLabとは無関係なのでcommit対象外。Pythonキャッシュ、テストで生成されたFunctions JavaScript、DerivedData、private config／匿名端末UID allowlist／認証情報／実通信evidenceも対象外。既存Firebase client plistは変更しない。

### feature branchへの保存対象（34ファイル）

- `.gitignore`
- `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Recognition-Lab.xcscheme`
- `Aogaku/AIInput/AIInputPreviewViewController.swift`
- `Aogaku/RecognitionLab/AppleLabSpeechRecognizer.swift`
- `Aogaku/RecognitionLab/RecognitionLabFixtures.swift`
- `Aogaku/RecognitionLab/RecognitionLabModels.swift`
- `Aogaku/RecognitionLab/RecognitionLabService.swift`
- `Aogaku/RecognitionLab/RecognitionLabViewController.swift`
- `Aogaku/RecognitionLab/RecognitionPricing.swift`
- `Aogaku/SceneDelegate.swift`
- `AogakuTests/RecognitionLabTests.swift`
- `Config/Info-Debug.plist`
- `docs/ai-input/RECOGNITION_LAB.md`
- `docs/ai-input/RECOGNITION_LAB_RESULTS.md`
- `firebase.recognition-lab.json`
- `recognition-lab/functions/package-lock.json`
- `recognition-lab/functions/package.json`
- `recognition-lab/functions/src/domain.ts`
- `recognition-lab/functions/src/index.ts`
- `recognition-lab/functions/src/pricing.ts`
- `recognition-lab/functions/src/providers.ts`
- `recognition-lab/functions/test/domain.test.cjs`
- `recognition-lab/functions/test/fixtures.json`
- `recognition-lab/functions/test/pricing.test.cjs`
- `recognition-lab/functions/tsconfig.json`
- `scripts/recognition_lab_assets.swift`
- `scripts/recognition_lab_audit.cjs`
- `scripts/recognition_lab_dev.py`
- `scripts/recognition_lab_device.cjs`
- `scripts/recognition_lab_e2e.cjs`
- `scripts/recognition_lab_pricing_e2e.cjs`
- `scripts/test_recognition_lab.swift`
- `scripts/test_recognition_lab_device.cjs`
- `scripts/test_recognition_lab_safety.py`

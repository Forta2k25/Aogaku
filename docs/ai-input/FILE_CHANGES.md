# 変更ファイルとGit状態（2026-10-06）

作業コピー：`/Users/shum/Documents/Codex/2026-10-06/y/work/Aogaku`。ブランチ `codex/ai-input-foundation`、HEAD `47d54c8c03247c9311acc0c3d7bcdd2f5046a997`。

本ターンではgit add/commit/push/PR/mergeを行っていない。既存のstaged内容は前の実装から残っている。stagedとunstagedの両方にあるファイルは、今回の追加修正がまだindexへ入っていない。

## 今回の変更理由

| ファイル | 理由 |
|---|---|
| `.firebaserc` | 本番default aliasを取り除き、自動で本番を選ばない |
| `.gitignore` | Dev/Productionの環境別Firebase plist・実Dev ID manifestを除外 |
| `Aogaku.xcodeproj/project.pbxproj` | Debugの別Bundle ID、Debug Info、元の本番plistの自動同梱除外、検査付きbuild script、Storyboard自動起動の除外 |
| `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Local.xcscheme` | 通信なしのRun / Debug |
| `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-Dev.xcscheme` | Devを明示するRun / Debug |
| `Aogaku/AIInput/AppBackend.swift` | 既定offline、環境/project/bundle照合、ローカル確認UID |
| `Aogaku/AIInput/AIInputPreviewViewController.swift` | 実UIへの入口、明示した状態サンプル、架空JPEG/PDF生成。Releaseには確認ボタンを出さない |
| `Aogaku/AIInput/SourceIngestionService.swift` | Firebase Functionsの遅延生成、offline時の送信抑止、端末内の再試行・削除・サンプル共有 |
| `Aogaku/AIInput/SourceLibraryViewController.swift` | offlineでも一覧を開き、クラウド一覧の取得を抑止、表示確認の明示 |
| `Aogaku/AppDelegate.swift` | SDK起動前のoffline/config照合、未設定時停止、Sceneを手動起動 |
| `Aogaku/SceneDelegate.swift` | 確認画面への起動、offline/config失敗時の通常アプリ・gatekeeper・URL処理を抑止 |
| `Aogaku/CourseDetailViewController.swift` | ローカルUID、初期AIタブ表示修正、offlineでポータル/広告を抑止、写真選択入力、確認用PDF初期フォルダ |
| `Aogaku/Info.plist` | 通常Storyboardの自動Scene起動を取り除きSceneDelegateに統一 |
| `Config/Info-Debug.plist` | DebugだけのFiles公開・Analytics無効化、Dev URL scheme、公式AdMobテストID。本番OAuth/広告IDをコピーしない |
| `Config/firebase-development.example.json` | 実Dev ID manifestの雛形。まだ実IDは未指定 |
| `scripts/prepare_firebase_config.py` | ローカルだけの環境別plist選択・照合・成果物へのコピー、古いplist除去 |
| `scripts/firebase_dev.py` | ローカルcheck、Dev限定のSecret登録/deploy、実project ID必須、本番拒否 |
| `scripts/check_firebase_deploy_target.py` | predeployのproject照合。ネットワーク操作なし |
| `scripts/test_firebase_config_safety.py` | 7件の環境混同・本番混入の回帰検証 |
| `firebase.json` / `firebase.dev.json` | Functions/Firestore/Storageのpredeployガード、TS build、Dev用CLI config |
| `docs/ai-input/README.md` | 古い本番defaultと汎用deploy手順を取り除き、新しい安全な手順へリンク |
| `docs/ai-input/SIMULATOR_AND_DEVELOPMENT.md` | Xcodeの開き方、環境分離、ユーザー準備、全サービス/API/IAM/費用、Vision/Groq設定 |
| `docs/ai-input/E2E_CHECKLIST.md` | 4カテゴリー、実行済み/未実施、4入力のE2E、障害・競合・権限の合格条件 |
| `docs/ai-input/FILE_CHANGES.md` | 前のstaged実装と今回の修正、生成物を区別した一覧 |

## 検証結果

- Simulator Debug build：Aogaku-AI-Local、iPhone 17/iOS26.0、SDK26.2、CODE_SIGNING_ALLOWED=NOで成功。
- 本番Firebase plistはDebug成果物に存在しない。Files公開はDebug成果物でtrue、Analyticsはfalse。
- Dev設定未登録のDevモード起動はFirebase初期化前に停止し、設定エラーを表示。
- 環境分離Pythonテスト7件、TypeScript build・サーバー単体10件、Swift端末保存テストを今回再確認して合格。
- Firestore/Storage Emulator6件は前の実装時に合格。今回はサーバー機能を変更していないため再実行していない。
- Swift単体compileは最初のcache/SDK設定で失敗したが、書込み可能なmodule cacheと明示したSDK/targetで再コンパイル・実行に成功。アプリのSimulatorビルドは成功。
- Vision/Groq・Dev Firebase実通信、実機・長時間録音は未実施。Release全体の回帰確認は未実施。

## staged（前の実装）：25件

```text
.gitignore
Aogaku/AIInput/LocalSourceStore.swift
Aogaku/AIInput/RecordingRecovery.swift
Aogaku/AIInput/SourceIngestionService.swift
Aogaku/AIInput/SourceLibraryViewController.swift
Aogaku/AIInput/SourceModels.swift
Aogaku/CourseDetailViewController.swift
Aogaku/NoteRecording.swift
contracts/ai-input/context-response.example.json
docs/ai-input/API.md
docs/ai-input/README.md
firebase.ai-test.json
firebase.json
firestore.indexes.json
functions/package-lock.json
functions/package.json
functions/src/ai/domain.ts
functions/src/ai/extractors.ts
functions/src/ai/index.ts
functions/src/index.ts
functions/test/domain.test.cjs
functions/test/emulator.test.cjs
functions/tsconfig.json
scripts/test_ai_store.swift
storage.lifecycle.json
```

## unstaged（追跡済みの今回の修正）：11件

```text
.firebaserc
.gitignore
Aogaku.xcodeproj/project.pbxproj
Aogaku/AIInput/SourceIngestionService.swift
Aogaku/AIInput/SourceLibraryViewController.swift
Aogaku/AppDelegate.swift
Aogaku/CourseDetailViewController.swift
Aogaku/Info.plist
Aogaku/SceneDelegate.swift
docs/ai-input/README.md
firebase.json
```

## untracked（今回の新規ファイル）：14件

```text
Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Local.xcscheme
Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-Dev.xcscheme
Aogaku/AIInput/AIInputPreviewViewController.swift
Aogaku/AIInput/AppBackend.swift
Config/Info-Debug.plist
Config/firebase-development.example.json
docs/ai-input/E2E_CHECKLIST.md
docs/ai-input/FILE_CHANGES.md
docs/ai-input/SIMULATOR_AND_DEVELOPMENT.md
firebase.dev.json
scripts/check_firebase_deploy_target.py
scripts/firebase_dev.py
scripts/prepare_firebase_config.py
scripts/test_firebase_config_safety.py
```

## 生成物：221件の追跡済み差分

`functions/node_modules/` と `functions/lib/` は元のリポジトリで既に追跡されており、依存関係の復元・TypeScript buildによる差分が残る。本質的なソース変更に含めない。既存差分や作業用依存関係を勝手に捨てていない。将来の統合前に生成物の扱いを別途決める必要がある。

XcodeのDerivedData、Swift package cache、Swift module cache、Simulatorの確認データはソース変更に含めない。ビルドログは `/Users/shum/Documents/Codex/2026-10-06/y/work/simulator-build.log`。

本番Firebaseへの読取り・書込み・deploy、GitHubへの更新、Aogaku-cleanのファイル編集は実行していない。Xcodeでは今回の作業コピーだけを開いてScheme/Simulatorを選んだ。もともと開かれていたAogaku-cleanの実行状態には操作を加えていない。


## Dev接続後の追加変更（2026-10-06）

この一覧の初回Simulator確認後の差分と変更理由は [DEV_CONNECTION_AND_RESULTS.md](DEV_CONNECTION_AND_RESULTS.md) の末尾に記録。Dev接続・実API E2E・Simulatorの実送信サービスE2Eを完了した。stagedの既存25ソース変更は保持し、このターンで追加stage・commit・pushをしていない。生成物は引き続きソースと分ける。

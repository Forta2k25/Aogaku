# Recognition Lab branchへの本番AI pipeline統合

2026-10-08、既存 `codex/ai-recognition-comparison-lab`（`b2a74c63ba3b`）へ、Phase 5a基点 `927a3d65c43ba863f94fc995aaef91e5abc0e02d` 上の `codex/ai-input-detection-results` の未commit差分を統合。新branch作成、merge、rebase、履歴rewriteは行っていません。patch事前照合・適用でconflictなし。

Labの既存UI、画像3方式、音声比較、料金設定、Dev匿名認証、Scheme、独立Dev codebaseは保持。新しい本番AI入力のQwen AI-only / Whisper Turbo / 検出結果 / recognition metadataと運用guardを追加しました。通常Aogaku SchemeのローカルDebug→Release変更はcommit対象外です。

本番移行の結果と10件のrevisionは `PRODUCTION_RECOGNITION_DEPLOY_RESULT.md` を参照。有効な本番非pilot Authでの実通信拒否確認は追加承認待ちという状態をそのまま記録し、完全完了したとは扱っていません。本統合作業ではFirebase／allowlist／Secret／Scheduler／sharing／deployを一切操作していません。

## 検証

- Functions TypeScript build / recovered build: PASS。
- pipeline / domain / migration / Phase5a / revision / read-only retry guards: 54/54 PASS。
- Recognition Lab unit / pricing tests: 22/22 PASS。
- Lab安全ガード: 5/5 PASS。Dev匿名認証ガード: 5/5 PASS。
- Production安全ガード: 保存済みprivate snapshotを使うローカル検証12/12 PASS。live cloudアクセスなし。
- named/default DB・Rules・worker・削除・旧機能・recognitionのEmulator回帰: 49/49 PASS。projectはdemo-aogaku-input、providerはmockのみ。
- offline Simulator Debug build / XCTest: 24実行、23 PASS / 1 Dev通信opt-in SKIP / 0 FAIL（Lab11、検出結果13）。
- 広めに追加実行した旧Phase4 completion/finalのprivate journal replay 2件は、移植先に過去のignored journalがなくENOENT。今回のsource変更に起因せず、過去evidenceをGitへ持ち込まず未変更で保持。関連する54件は全PASS。

ローカルJavaがPATHにない／旧配置の起動失敗は、既存JDK archiveをignored buildに展開して解消。JDK・Emulator・ログはcommitしません。

## branch統合のための運用コード調整

- offline artifact prepare guardは移行元と統合先の2 feature branchesを許可し、mainは拒否。
- private旧停止journalを読む新guardテストは、evidenceがないcloneではSKIP。pureなqueue drain / endpoint / mutation拒否テストは常時実行。
- Lab safety testは、同居するproduction pipelineの意図したsource変更ではなく、Labの独立codebase・production設定不変・DB/queue IO禁止を検証。

## privacyと除外

tracked treeおよび追加候補をscanし、private UID、Groq key、JWT、signed upload URL、実private keyの混入なし。private設定から読み取ったUIDはメモリ内で比較し、値を出力・記録しません。既存Firebase client plistは変更せず保持。既存空PEM例とlibraryのPEM import markerは実credentialではないことを確認。

private config / .env / Auth token / registry / production evidence / Dev result fixture / build / DerivedData / node_modulesはstageしません。古い履歴で既にtrackedのFunctions生成物も今回のbuild差分を含めません。`functions/lib/index.js` はbuild前のHEAD版へ戻し、生成された版はignored backupに保持。`scripts/__pycache__/firebase_dev.cpython-311.pyc` と通常Aogaku Schemeの既存差分はローカルに残します。

## 今回のcommit対象

- `Aogaku.xcodeproj/project.pbxproj`
- `Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Input-Tests.xcscheme`
- `Aogaku/AIInput/AIAppCheck.swift`
- `Aogaku/AIInput/AIDetectionResult.swift`
- `Aogaku/AIInput/AIDetectionResultView.swift`
- `Aogaku/AIInput/AIInputSession.swift`
- `Aogaku/AIInput/AppBackend.swift`
- `Aogaku/AIInput/SourceIngestionService.swift`
- `Aogaku/AIInput/SourceModels.swift`
- `Aogaku/CourseDetailViewController.swift`
- `Aogaku/PushManager.swift`
- `Aogaku/SettingsHostViewController.swift`
- `Aogaku/timetable.swift`
- `AogakuTests/AIDetectionResultTests.swift`
- `docs/ai-input/DETECTION_RESULTS.md`
- `docs/ai-input/IMAGE_AI_ROUTE_FIX.md`
- `docs/ai-input/PRODUCTION_RECOGNITION_DEPLOY_RESULT.md`
- `docs/ai-input/PRODUCTION_RECOGNITION_DEPLOY_STOP.md`
- `docs/ai-input/PRODUCTION_RECOGNITION_REVIEW.md`
- `docs/ai-input/RECOGNITION_PIPELINE_INTEGRATION.md`
- `firebase.detection-test.json`
- `functions/src/ai/admission.ts`
- `functions/src/ai/domain.ts`
- `functions/src/ai/extractors.ts`
- `functions/src/ai/index.ts`
- `functions/src/ai/pricing.ts`
- `functions/src/ai/recognition.ts`
- `functions/test/emulator.test.cjs`
- `functions/test/recognition.test.cjs`
- `scripts/audit_image_route_dev.cjs`
- `scripts/deploy_detection_dev.py`
- `scripts/deploy_production_recognition.cjs`
- `scripts/detection_dev_e2e.cjs`
- `scripts/image_route_assets.swift`
- `scripts/image_route_dev_e2e.cjs`
- `scripts/production_recognition_auth.cjs`
- `scripts/production_recognition_e2e.cjs`
- `scripts/production_recognition_review.cjs`
- `scripts/run_detection_emulator.cjs`
- `scripts/test_production_recognition_deploy.cjs`
- `scripts/test_production_recognition_review.cjs`
- `scripts/test_recognition_lab_safety.py`

# Selected-route Evidence adoption audit

本書は本番移行前のDev監査記録。後続の承認済み本番移行は `production-visual-router-rollout.md` を参照する。

2026-10-09。対象branchは `codex/ai-recognition-comparison-lab`。未commitのGrounded promptは保持した。

## 原因と環境

利用者が結果を見たSchemeは通常 `Aogaku`（Release、本番接続）。本番 `aiListSources` と `aiProcessSource` の現在稼働ソースをSourceCodeGetで読み取り確認した。どちらもVisual Router未導入で、旧PDF抽出を使用する。旧処理はページのnative文字が20文字未満ならVision OCR、それ以外はnative textを採用する。図は解釈せず `figures_not_interpreted` を付ける。p4の文字一覧、p25の見出しだけ、p27のOCR断片という表示はこの経路に整合する。

本番資料のsourceIdは未提示なので個別レコードは取得していない。稼働ソースとSchemeから接続先・旧処理方式を確認した。本番でQwen本文を生成してから落とした、というバグではない。

Devの現在稼働worker、Evidence、retrieve APIのRouterコードはローカルと一致。workerのGrounded promptも一致する。`pageResult` はselected routeごとに本文を一つだけ採用しており、AIならprovider parserのfinalTextをUnitにする。native/OCRを追加するコードはない。workerはそのUnitだけからchunksを作る。APIはactive runのchunksを返し、iOSはその同じ本文をUTF-16 offsetで重複除去して表示する。

## Fresh Dev検証

承認済み原本30ページを新規sourceとしてDevへ送信。抜粋によるページ番号変更なし。`scripts/evidence_adoption_dev.cjs` はDev固定で、token、UID、原本、checkpoint、API返却、比較本文をignored build/private fixtureだけへ保存する。deployや設定変更はしない。

各ページをnative extraction、Router decision、selected route、OCR probe、provider後checkpointのUnit、chunks、Evidence、retrieveと比較する。Groqのraw応答は保存しない。Qwen finalTextの参照は、稼働parserがfinalTextだけを保存したpost-provider checkpointであり、raw応答を別取得したとの主張はしない。provider回帰ではnative/probeとは異なるfinalTextを返し、選択route本文だけが保存されることを検証する。

- native 23ページ、AI 7ページ、OCR final route 0ページ。
- p4/p15/p25/p27すべて `multimodal_ai / groq / qwen/qwen3.8-27b`。これらの4ページは構造上明確なvisualなのでOCR probeも実行しない。
- p4: Observation→Question→Hypothesis→Experiment→Conclusion→Resultの5接続を保存。Result→Observationなし。
- p15: 4項目リスト、Creationismの絵画、Physiognomyの顔画像群の配置を保存。固有の作品名・人物名なし。
- p25: 8宗教のシンボルと名称を保持。小さな説明文は判読不能とする。
- p27: 左の表紙、右のステンドグラス風人物、読める見出しを保持。OCR全文を連結しない。ただしQwen自身が手書き引用FOUET/VOUSをFOUE/NOUSと誤読した。この転記品質は未解決で、全面的なgrounding品質PASSとはしない。
- p6などnativeページはUnit.textとnative結果が一致し、OCR probeなし／AI token数0。

4対象ページはUnit→chunks→aiGetEvidence→aiRetrieveContextで全文一致。pageNumberと文字offsetを維持し、iOSは `[p.N]` を付けた同じ自然文を表示する。UIのDebug診断に実route/provider/modelを追加した。旧native/OCR本文をQwenとして表示する変更はしない。

30ページ成功runのusage合計は11,516 tokens、既存料金による推定$0.0175688。失敗したprovider callの実請求額を含む請求集計ではない。Groq429後、既存Tasks再試行と一度の明示aiRetrySourceで同じsourceのcheckpointを再利用した。完了ページを別sourceで重複処理せず、OCR fallbackも使わない。

## 回帰と境界

- TypeScript build PASS。
- domain/recognition/Router/safety 46件PASS。
- Emulator 50件PASS。selected AI finalTextのみ、Firestore chunks/API/searchの本文・locator一致、再送・削除・legacy回帰を含む。
- Phase5a/revision/Router/deploy guards 17件PASS、fresh offline production review guards13件PASS、adoption operator guards2件PASS。
- Python prompt/environment safety12件PASS。
- Simulatorはoffline専用 `Aogaku-AI-Input-Tests` のDebugで16件PASS、Dev network opt-inの1件はskip。今回の実Dev返却fixtureを実際の検出結果Viewへ渡すテストもPASSし、対象4ページの本文完全一致を検証した。fixtureはGit除外。

以前のoffline production reviewはprompt変更前artifactなのでguardが拒否した。旧artifactをprivate buildへ保存したうえで新artifactを生成し、guardを再実行した。実deployの承認としては使用しない。

本番への移行は改めて承認が必要。schema5/auto-route capability/receipt/recognition契約を揃える10件は `aiCreateSource`, `aiCompleteSource`, `aiGetSource`, `aiListSources`, `aiGetEvidence`, `aiRetrySource`, `aiUpdateSource`, `aiDeleteSource`, `aiRetrieveContext`, `aiProcessSource`。本番のallowlistなどenvを保持し、fresh preflight、queue pause/drain、source-only更新、source/protected audit、queue復旧を別承認で実行する。既存資料は再処理しない。

今回変更はUI診断、本文採用の回帰、Dev trace operatorと本書。Router threshold、route判定、backend処理契約、モデル、audio/note、quota、Rules/IAM/Secret/allowlist/sharingは不変。本番はmetadataとsourceの読み取りのみ。commit/pushは実施しない。通常Aogaku Schemeとpycacheの既存変更は保持する。

使い捨てDev Auth削除後、owner/sourceはdeleted tombstone、runs/chunks/jobs/usage periodsとAI原本/派生Storageはcleanup済み。ローカルregistryからtokenを除去した。final metadata/IAM/Rules/indexes/Secret/bucket/Functions auditは不変、Dev queue RUNNING、既存Dev Scheduler状態も不変。比較本文とXCTest fixtureはignored local evidenceとして保持する。変更source/docsのprivate UID・credential scanはPASS、staged diffは空。

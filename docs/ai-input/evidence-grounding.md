# Multimodal Evidence grounding prompt

2026-10-09、Visual Router v1の本番移行前。変更するbackend実装は `functions/src/ai/recognition.ts` のEvidence生成prompt文と、その指示をsystem priorityへ分離する部分だけ。画像はuser inputとして送る。

## 出力の目的と契約

教材解説を生成せず、渡された画像の印刷文字・線・矢印・囲み・位置を転記／構造化する。円形配置や一般的な工程名から閉ループを補完しない。見えない関係、因果、作品名、人物名、領域、個数は生成しない。不鮮明な文字は語感や一般知識で埋めず、確認できない部分を明記する。

Qwenへの要求JSONは `visibleText` / `visibleRelations` / `description` / `uncertainty` / `finalText`。中間分類はprovider応答内部に限定。既存parserは従来どおり自然文 `finalText` だけをUnit／Evidence／chunksへ保存する。providerのraw JSONや追加分類をFirestoreへ保存する契約は導入しない。既存finalText-only応答も読める。

model `qwen/qwen3.8-27b`、temperature、reasoning設定、max completion tokens、usage/cost計算、pipelineVersion、Router threshold／route判定／checkpoint key、callable契約は不変。旧ready資料と既存checkpointを自動再処理・上書きしない。今回のDev検証はfresh sourceを使用する。

## 指定PDFの再検証方法

原本のp4/p15/p25/p27を4ページ抜粋PDFへコピーし、ignored build内だけに保存。PDF.jsで元ページ／抜粋ページを同じrendererで描画し、4/4でPNG byte一致を確認した。抜粋PDFのlocator 1/2/3/4を元ページ4/15/25/27に対応させる。元PDF／GoodNotes未変更。

Devだけでfresh metadata／IAM／Rules／indexes／Secret metadata／bucket／queue／Schedulerを取得する。queueを一時PAUSEしてdrainを確認し、`deploy_detection_dev.py --evidence-prompt` で `aiProcessSource` 1件だけ更新する。新しい稼働sourceの全AI JavaScript modules／package manifestをSourceCodeGetでlocalと照合し、その他16 Functionsのmetadata、業務env、IAM、Rules、indexes、Secret、Schedulerが不変の場合だけqueueをRUNNINGへ復旧する。

CLIはworker update operation成功・Deploy complete後に、ローカルupdate config storeの権限警告とexit 2を返した。source更新の再実行は行わず、read-only live source/config/protected auditで確認する。API GETの一時503は既存限定retryだけを使用する。mutation自動retryやforceは使用しない。

## 初回検証と修正

初回promptではp4の未描画の戻り矢印は解消した。しかしp15で印刷されていない作品名と存在しない下部領域を補完していたため、4ページ全面PASSとはしなかった。promptを再度厳格化し、全固有名詞と領域／リスト／図版の実在チェック、未確認事項の省略、小文字の断片的な転記を明示した。初回の結果は別private evidenceへ保存し、Auth／原本／派生物をcleanupした。再修正版もp4の戻り矢印は追加しなかったが、p15の上下領域の重複を再度生成したため不合格とした。

最終promptでは長い場面説明を求めず、Evidenceの中心を判読文字と実際のconnectorへ変更した。任意descriptionは短い見える物の記録に限り、ページの領域分割・個数・物語的説明を要求しない。反復2回目のfixtureもcleanupし、3回目は別のfresh sourceで検証した。3回目では4ページとも未描画の関係・p15の二重領域・印刷されていない作品／人物名は生成しなかった。ただしp25の細い英字とp27の手書きフランス語に誤読が残り、転記品質の全面PASSとはしなかった。最終promptでは小さな図版内文字／吹き出しについて完全な引用を作らず、確実な短い断片と「判読できない」に留める。4回目も別のfresh sourceで確認した。4ページに未描画の関係は追加されず、p25の細字補完もなくなった。一方p27では長い手書き引用を省く指示が守られず、誤読が残った。5回目では指示をsystem promptへ分離し、画像をuser inputに限定する。単に処理がreadyになったことを視覚的な正しさのPASSとは扱わない。

## 安全性と回帰

- TypeScript build、domain／recognition／Router／Router safety 46/46 PASS。
- Emulator保存／再送／削除／権限／legacy回帰50/50 PASS。
- Phase4/5a／target／deploy guards31/31 PASS。
- Python環境分離／production safety／Dev single-worker selector35/35 PASS。
- Structured provider応答でも最終Evidenceへ中間JSONが混入せず、実usageと既存cost契約を保つunit testを追加。
- 以前のproduction offline reviewはこのprompt変更前のsource hashを持つ。今回の本番承認artifactとして再利用できず、本番移行前にfresh artifactが必要。

private UID／token／registry／source ZIP／指定PDF／返却本文はignored buildのみ。iOS UIは変更していない。運用scriptと回帰testを追加・適合した。本番アクセス／deploy／設定変更、Router threshold変更、main mergeは行わない。

## 変更ファイル

- `functions/src/ai/recognition.ts`: multimodal Evidence prompt文とsystem priorityのみ変更。
- `functions/test/recognition.test.cjs`: structured応答からfinalTextだけを保存する契約回帰、system指示とuser画像の分離。
- `functions/test/emulator.test.cjs`: provider mockのmessage参照をsystem／user分離へ適合（期待するEvidence・route・usageは変更しない）。
- `scripts/deploy_detection_dev.py`: prompt変更用のworker 1件限定selector。
- `scripts/test_evidence_prompt_dev.py`: cohort／target／混合selectorの安全確認。
- `scripts/visual_router_dev.cjs`: 既存read-only／snapshot helperのexportのみ。
- `scripts/evidence_prompt_dev.cjs`: fresh Dev audit、指定ページE2E、disposable fixture cleanup。
- 本ドキュメント: 目視比較・回帰・保護設定の記録。

通常Aogaku Schemeの既存ローカル変更は対象外で保持する。Git commit／pushは今回実施しない。

## 最終Dev目視比較（system prompt版）

4ページともsourceはready、route／provider／modelはmultimodal_ai／groq／qwen/qwen3.8-27b。最終Evidence→chunks→retrieve contextの保存・取得契約はPASS。元ページとの比較では未描画の関係追加は4/4で見られなかった。

| 元ページ | 目視比較 |
| --- | --- |
| 4 | Observation→Question→Hypothesis→Experiment→Conclusion→Resultの5接続のみ。Result→Observation／閉ループを追加しない。 |
| 15 | 一組のリストとCreationism／Physiognomyの画像。二重の上下領域、印刷されていない作品名を追加しない。細字は判読不能と記述。 |
| 25 | 実際の見出しと宗教名／図形のみ。細字を推定復元しない。未描画の矢印・因果なし。 |
| 27 | 作品／人物の身元や画像間の関係を補完しない。ただし手書きフランス語の引用に誤読が残る。 |

p27の引用は原文FOUET／VOUSに対し、FOUE／NOUSを出力した。全文引用を省くsystem指示も守られていない。promptだけで判読文字の品質を全面保証できたとはしない。今回の関係追加防止確認は4/4 PASSだが、転記品質／本番品質承認はNOT FULL PASSとして記録する。無理に手書き文字全体を対象外にする処理や、出力後の恣意的な削除・置換は追加していない。

最終4ページのAPI usage合計: input 5,892／output 925／total 6,817 tokens、推定cost $0.0084136。料金計算は既存のまま。429は既存Tasks再試行とページcheckpointで回復し、OCR fallbackや重複fixture送信はしなかった。

変更はDev workerだけ。本番deploy／アクセス、Router threshold／route変更、モデル変更、Rules／indexes／IAM／Secret／allowlist変更、Git commit／pushは行っていない。

最終cleanup／protected auditもPASS。使い捨てDev Authを削除し、registry内のtokenを除去した。資料とownerはdeleted tombstoneで保持、原本／派生物／runs／既知のactive run配下chunks／jobs／usage periodsは削除を確認。Dev queueはRUNNINGへ復旧し、既存Dev SchedulerのENABLED状態は不変。その他16 Dev Functions、IAM、named/default Rules／indexes、Secret metadata／version、bucket lifecycleも不変。

# 授業AIの回帰評価

製品promptを変える前にbaselineを取得する。本番FunctionsやFirestoreは使わず、現在のTypeScriptを一時ディレクトリにコンパイルし、製品と同じ `buildMessages / geminiChatStream` でGemini Developer APIを呼ぶ。API費用が発生する。キーは `GEMINI_API_KEY` のみで渡し、CLI引数や設定ファイルへ書かない。

## 実行

リポジトリのルートで：

```sh
python3 scripts/make_grounding_fixtures.py build/tutor-eval/fixtures
node --test scripts/tutor-eval/core.test.cjs scripts/tutor-eval/runner.test.cjs
node scripts/tutor_eval.cjs --list
node scripts/tutor_eval.cjs --split dev --repeat 3 --out build/tutor-eval/runs/before
# 最小修正・unit test後に同じ条件で：
node scripts/tutor_eval.cjs --split dev --repeat 3 --out build/tutor-eval/runs/after
node scripts/tutor_eval_compare.cjs build/tutor-eval/runs/before build/tutor-eval/runs/after
# 重要ケースだけを反復（別の部分集合として比較）：
node scripts/tutor_eval.cjs --only legacy-04,legacy-05,legacy-07 --repeat 10 --out build/tutor-eval/runs/critical
# dev作業終了後、独立した最終確認：
node scripts/tutor_eval.cjs --split holdout --repeat 3 --out build/tutor-eval/runs/holdout
```

`--fixtures PATH` で画像のフォルダを変更できる。出力先は既存フォルダへの上書きを禁止する。生成物はgitignore対象のbuild配下へ置く。指定のないcase、無効なrepeat、空の選択はネットワーク実行前に拒否する。

終了コード：0=自動必要条件を全件通過（**品質合格を意味しない**）、2=自動チェック失敗またはAPI障害、1=設定/コンパイル/入力等の問題。

## 採点とレビュー

- `autoChecksPass`：必要な式や禁止事項など、機械判定できる必要条件。
- `legacy`：元の8ケースと同じキーワード判定の参考結果。legacy-03は新runnerでは実会話を使うため、旧scriptの仮履歴による成功率と直接比較しない。
- Hard gates：grounding / correctness / task_completion / uncertainty。それぞれpass / fail / unscored。**未採点を成功に数えない**。
- Soft metrics：clarity / conciseness / suggestions、0〜2。未採点はnull。
- suggestionsの機械診断：2件、20文字以内、重複と汎用的な固定候補、教材anchorへの言及。anchorだけで教材固有性や学習価値の合格判定はしない。

`review-template.json` をコピーし、`cases.json` のrubricと各結果の全文を照合して、gateごとの判定と具体的な理由を記入する。clarityは説明の正確さと理解の助け、concisenessは設問を飛ばさず必要最小量か、suggestionsは教材固有性・次のつまずき・重複を評価する。0=不足、1=一部不足、2=満たす。複数ターンの試行は全ターンが合格して初めて合格。

```sh
node scripts/tutor_eval_review.cjs build/tutor-eval/runs/before build/tutor-eval/reviews/before.json
node scripts/tutor_eval_compare.cjs build/tutor-eval/runs/before build/tutor-eval/runs/after build/tutor-eval/reviews/before.json build/tutor-eval/reviews/after.json
```

人によるレビューが自動判定の誤検出を覆す場合も、理由を必ず記録する。元の自動診断は消さない。採点器の問題はrubric versionまたはscoring hashを変え、保存済み応答を同じ採点器で再採点して比較する。旧判定と新判定の数字を品質改善として報告しない。

```sh
node scripts/tutor_eval_rescore.cjs build/tutor-eval/runs/before build/tutor-eval/runs/before-rescored
```

再採点は保存時のcases.jsonと可視streamを使い、モデルは呼ばない。元の計測値・入力hashを保持し、新しいscoring hashと派生元runを記録する。既存の内容レビューは自動適用しないため、レビューを使う場合は新しいrunIdへ明示的に対応付け直す。

## Dataset

`cases/dev`：既知の画像8ケース、微分/積分訂正2ケース、論理・制約方向・英文法3ケース、別内容の説明/項の網羅variation3ケース、前回確認済みの単位変換・中央値・和事象確率3ケース（合計19）。`cases/holdout`：端点最適化・逐次割引・全称と存在の区別の別family3ケース。現時点では小さなseed datasetであり、広い一般化の保証ではない。

`schema.json` は形式の契約。runnerは依存ライブラリ不要の入力検証も行う。id・version・familyId・split・tags・source・question scenario・gate別rubric・必要条件を1ケースにまとめる。
画像は元の `make_grounding_fixtures.py` で再生成し、実行時のbyte hashを保存する。バイナリをdataset JSONへ埋め込まない。familyIdがsplit間に重複すると起動を拒否する。ただし意味的な重複は人が確認する必要がある。

新しい失敗は原例と別内容のvariationをdevへ追加する。最初からholdoutへ既知の失敗を移さない。初回holdoutの応答は開発中に確認したため、`split-history.json`に記録してdevへ移動した。補充したholdoutは最終確認にのみ使う。holdoutは開発中に実行せず、失敗を見て修正したケースは次回からdevへ移し、新しい独立familyで補充する。本datasetを編集したエージェントから意味内容を隠せる仕組みではなく、運用上の分離である。

## 記録と比較

manifest：commit / dirty / diff hash / 製品source hash / prompt hash / runner hash / dataset hash / fixture hash / scoring hash / rubric version / model / generation設定hash / split / repeat / case一覧。
results.jsonl：1行1ターン、実応答の本文・可視stream・候補・判定・最初の可視文字までの時間・完了時間・tokens・USD推定費用・料金version・HTTP状態・試行回数。
内部作業メモ・キー・Base64画像は保存しない。内容レビューをCodexが行った場合はreviewerへ明記し、独立した第三者や人間の承認と扱わない。実教材や学生情報を入れた結果は公開しない。API障害の本文は入力やキーを反射する可能性があるため、記録するのは状態コードとアプリのエラーコードのみ。

summary：試行ごとの全gate成功、品質不合格、未採点、APIエラーを分け、全試行を分母にした成功/失敗率を示す。初回表示/完了のp50/p95と標本数、既知の費用合計・平均・不明件数、soft scoreの平均と採点数、case別の結果を保存する。繰り返し結果はケースごとの成功数/試行数で確認する。少数試行のp95は目安。
費用は製品のusage計算による推定で請求額の保証ではない。API障害時の費用は不明。再試行の費用が最終usageに含まれない場合もあるためattemptsも確認する。円換算は行わない。

比較はdataset・fixture・採点器・rubric・split・repeat・transport・生成設定が一致し、全予定ターンが完了したときだけ行う。promptとmodelの変更は実験として認め、model変更は比較結果に明示する。差分は同条件での確率的な結果であり、単発の変化を因果効果と断言しない。

## 原因分類と未カバー範囲

観測したhard gate不合格と根本原因を分ける。原因の候補：context_missing / structured_data_missing / conversation_state / vision / grounding / reasoning / task_interpretation / uncertainty / verbosity / suggestion / transport / evaluator。まず資料到達、構造化情報、会話stateの順に確認し、promptを強くするだけの修正へ飛ばない。

このrunnerはモデル呼び出しの品質を対象とし、iOSの写真選択、所有権確認、Firestoreのchunk選択、aiChat callableのMATERIAL_UNAVAILABLE判定そのもののE2Eではない。これらは別のオフライン/Emulatorテスト層で追加する。holdoutには現時点で写真の独立familyがなく、視覚の一般化検証も今後の拡充対象。


## 別モデルの評価（製品のモデルは変えない）

`--model` は評価プロセス内だけで対象モデルを明示する。製品のsourceやFunctions設定は変更しない。同じbuildMessages / parser / streaming経路を使う。モデル一致チェックは維持し、要求した名前と返却モデルが一致しなければ最初の1試行で全実験を中止する。APIのモデル一覧にある名前でもaliasの解決先が変わることがあるため、返却モデルを確認する必要がある。未登録の単価は`null / unpriced_model`とし、Liteの料金を流用しない。

```sh
node scripts/tutor_eval.cjs --model gemini-3.6-flash --only legacy-04,legacy-07 --repeat 3 --out build/tutor-eval/runs/model-comparison
```

2026-10-19のAPI確認ではgemini-3.5-flashの返却modelVersionがgemini-3.6-flashだったため、3.5名の試行は品質比較に使わない。実際のモデル名でもGETが成功することを確認してから再測定した。この記録は将来のaliasや料金を保証しない。

## 保存済み試行の部分集合比較

```sh
node scripts/tutor_eval_select.cjs build/tutor-eval/runs/subset legacy-04,legacy-07 build/tutor-eval/runs/before
```

部分集合の抽出は追加のモデル呼び出しを行わず、本文・計測値を保持する。元manifestのhashと抽出scriptのhashを記録し、対象ケースが重複する入力や、source / prompt / model / 生成設定 / split / repeat / 採点器が混ざる入力を拒否する。入力元が複数でも、同じ条件の異なるケースだけならまとめて抽出できる。派生したrunをAPI費用へ二重計上しない。


## 正常完了と途中出力（2026-10-19）

製品のchatはproviderの終了理由`STOP`を確認したときだけ返信を確定する。途中のdeltaは暫定であり、MAX_TOKENS / RECITATION / SAFETY / 終了理由欠落で完了した返信を返さない。非streamでも同じ契約とし、既存のCHAT_INVALID_RESULTを非retryableで返す。自動の追加LLM callはない。

evalはSSEのコピーからmodelVersion・finishReason・usageだけを抽出し、`provider`へ保存する。raw SSEや作業メモはファイルへ保存しない。本文に正解キーワードがあっても、観測した終了理由が不完全ならtask_completionを失敗にする。過去のmetadata未記録runは`unobserved`であり、STOPだったとは推定しない。

`maxOutputTokens`はモデルの内部思考にも消費される場合がある。別モデルの比較では、本文の途中停止と推論の誤りを区別する必要がある。今回の強いモデルを使った再現では、1,600tokenの枠の大半を思考が使用していた。モデル変更・budget拡大は本番へ反映していない。

エラーは`transport / model_identity / provider_output`を区別する。`executionErrors / errorsByCategory`が全実行エラーであり、互換性用の旧`apiErrors`フィールドにはHTTP 200で起きたモデル不一致・出力不正も含まれる。

比較の`gateRegressions`は、全体の合格数が変わらなくてもケース別・hard gate別に不合格が増えた場合を検出する。総合点だけで回帰なしとは判定しない。

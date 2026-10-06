# Callable API v1

リージョン `asia-northeast1`。すべてFirebase Auth必須。クライアントからFirestore/Storageの管理レコードを直接操作しない。

## Source受付

`aiCreateSource`:

```json
{"clientRequestId":"stable-uuid","type":"note","title":"第1回メモ","mime":"text/plain","text":"授業内容","size":12,"context":{"localCourseId":"course-code","classDocId":"classesのdocument ID","year":2026,"semester":"fall","dayID":20732,"occurrenceKey":"default"}}
```

`classDocId` は省略可。`type` は `image|pdf|audio|note`。ファイル入力では `size` が必須、audioは `durationSeconds` も必須。メモのサイズはサーバーが本文から求める。同じ利用者・同じ `clientRequestId` は同じ資料になる。内容が変わった再利用は `REQUEST_CONFLICT`。削除済みIDの再利用は `SOURCE_DELETED`。

返却はSource状態と、ファイル入力だけ `upload:{url,headers}`。`upload` があれば指定ヘッダー付きPUT後に `aiCompleteSource({sourceId})`。PUTは上書き不可なので再送が412になる場合は完了APIで実物を検査する。メモも完了APIを呼んでよい。

Source状態: `awaiting_upload → queued → extracting → indexing → ready|partial_ready|failed`。削除は `deleting → deleted`。

## 状態・一覧・編集

| API | 入力 | 動作 |
|---|---|---|
| `aiGetSource` | `sourceId` | 本人の状態 |
| `aiListSources` | `courseOfferingId` または上の `context`、`onlyLecture?`、`lectureId?`、`after?` | 本人と検証済み授業共有の一覧、最大100文書を走査 |
| `aiGetEvidence` | `sourceId`、`after?` | 読める抽出本文20断片と出典位置、`nextCursor` |
| `aiRetrySource` | `sourceId` | 本人の失敗・部分成功を再処理 |
| `aiUpdateSource` | `sourceId`、`title?`、`knowledgeVisibility?`、`rawVisibility?` | 所有者のみ、共有には所属検証が必要 |
| `aiDeleteSource` | `sourceId` | 所有者のみ、参照停止→原本と派生物削除 |

一覧の `nextCursor` は取得範囲を進めるための不透明な値。見える資料が0件でもカーソルがあれば次ページを取得する。本人専用の別授業や別年度は一覧・本文・検索対象にならない。rawVisibilityの設定値を原本取得権限として使う拡張は今後の実装で、現行APIは原本URLを返さない。

## 出力側の根拠取得

`aiRetrieveContext`:

```json
{"courseOfferingId":"aiListSourcesまたは受付で返ったID","lectureIds":["lecture-id"],"purpose":"question","query":"社会契約について説明して","maxCharacters":12000}
```

`lectureIds` 省略/空配列はその授業の全回。最大30回。`purpose` は `question|lecture_summary|exam_review`。questionだけ `query`（最大2,000文字）が必須。文字予算は1,500〜30,000、既定12,000。必要なら前の応答の `nextCursor` を `after` に渡す。

返却項目:

- `schemaVersion:1`、`contextRevision`（権限と有効版を再確認した時点の識別子）
- `items`: 本文、`sourceId`、`sourceVersion`、`activeVersion`、`lectureId`、`sourceType`、`chunkId`、`locator`、`flags`、`method`
- `locator`: PDFの `pageNumber`、音声の `startMs/endMs`、メモの `startChar/endChar`（JavaScript UTF-16位置）、画像の `imageIndex`
- `coverage`: `readySources/processingSources/partialSources` と、各Sourceの `totalUnits/processedUnits/failedUnits`
- `retrievalMethod:"lexical-ja-v1"`、`truncated`、`nextCursor`

1回にSource30文書、各Source80断片まで走査する。上限・文字予算で省略した場合は `truncated` を返す。Sourceの続きは `nextCursor`、特定Sourceの本文の続きは `aiGetEvidence` を使う。要約は資料ごとの断片を順に選ぶため、長い1資料だけで予算を消費しない。

このAPIは回答の生成をしない。返却0件や未処理がある場合は、その状態を利用者に伝える。処理中・共有取消・削除により応答が変わるので、無期限にキャッシュしない。

## エラーと再試行

認証なしは `unauthenticated`、他人の管理操作は `permission-denied`、本文の権限外は `not-found`。業務エラーは `failed-precondition` と `details:{code,retryable}`。代表例: `UPLOAD_INCOMPLETE`、`UPLOAD_MISMATCH`、`QUOTA_EXCEEDED`、`MEMBERSHIP_NOT_VERIFIED`、`RAW_EXPIRED`、`RETRY_LIMIT`。端末の未送信データはエラーが返っても削除しない。

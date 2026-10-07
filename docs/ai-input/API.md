# Callable API（年度別授業snapshot対応）

リージョン `asia-northeast1`。すべてFirebase Auth必須。クライアントからFirestore/Storageの管理レコードを直接操作しない。

Firestoreの実保存pathは `functions/src/ai/schema.ts` の11種類に限定し、旧レビュー用 `entries` は使用しない。iOSはこれらのpathを直接指定しない。[schema一覧とRules境界の未解決事項](SCHEMA_COLLISION_AUDIT.md)を参照。正規schemaが拒否されることだけでは、schema外の任意pathも拒否される保証にはならない。

## Source受付

`aiCreateSource`:

```json
{"clientRequestId":"stable-uuid","type":"note","title":"第1回メモ","mime":"text/plain","text":"授業内容","size":12,"context":{"localCourseUUID":"11111111-1111-4111-8111-111111111111","classDocId":"00004","syllabusUrl":"https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=1611020-0004","courseName":"授業名","teacherName":"教員名","year":2026,"semester":"fall","dayID":20732,"occurrenceKey":"default"}}
```

`classDocId` は5桁ゼロ埋めID、省略可。新規受付は永続的な `localCourseUUID` が必須。`localCourseId` は旧受付互換用で、新規資料の識別には使わない。年度はURLの `YR` → context.year（時間割）→ unresolved。現在年は使用しない。年・classDocIdが揃う場合のIDは `2026:00004`、学期はsnapshotとlectureIdに保持し、courseOfferingIdには含めない。`type` は `image|pdf|audio|note`。ファイル入力では `size` が必須、audioは `durationSeconds` も必須。メモのサイズはサーバーが本文から求める。同じ利用者・同じ `clientRequestId` は同じ資料になる。内容が変わった再利用は `REQUEST_CONFLICT`。削除済みIDの再利用は `SOURCE_DELETED`。

返却はSource状態、保存時の `courseSnapshot` と明示的紐付け時の `canonicalSnapshot`、およびファイル入力だけ `upload:{url,headers}`。`upload` があれば指定ヘッダー付きPUT後に `aiCompleteSource({sourceId})`。PUTは上書き不可なので再送が412になる場合は完了APIで実物を検査する。メモも完了APIを呼んでよい。

Source状態: `awaiting_upload → queued → extracting → indexing → ready|partial_ready|failed`。削除は `deleting → deleted`。

## 状態・一覧・編集

| API | 入力 | 動作 |
|---|---|---|
| `aiGetSource` | `sourceId` | 本人の状態 |
| `aiListSources` | `courseOfferingId` または上の `context`、`onlyLecture?`、`lectureId?`、`after?` | 本人と検証済み授業共有の一覧、最大100文書を走査 |
| `aiGetEvidence` | `sourceId`、`after?` | 読める抽出本文20断片と出典位置、`nextCursor` |
| `aiRetrySource` | `sourceId` | 本人の失敗・部分成功を再処理 |
| `aiUpdateSource` | `sourceId`、`title?`、`knowledgeVisibility?`、`rawVisibility?` | 所有者のみ、共有には所属検証が必要 |
| `aiLinkSourceOffering` | `sourceId`、5桁 `classDocId`、年度未解決時の `year?` | ownerが明示的に未解決資料をcanonical offeringへ紐付ける。元snapshot・受付ID・本文は保持、共有はprivateへ戻す。既知年度不一致は拒否。再送は最初の紐付けsnapshotを保持 |
| `aiDeleteSource` | `sourceId` | 所有者のみ、参照停止→原本と派生物削除 |

`courseSnapshot` は `courseOfferingId,classDocId,year,semester,syllabusUrl,courseName,teacherName,localCourseUUID,resolution,yearSource`。新規保存時のみ確定し、classes更新で再計算しない。year/classDocIdは未解決時null。lookupのcontextも保存済みURL／年度を使用し、現在のclassesから過年度を解決し直さない。受付の返却IDによる検索が確実な方法。カタログURL補完で年度が初めて判明したAPI利用者は、返却snapshotを保持して後続の一覧・検索に使う。

旧ハッシュIDは読取り・検索・同じ受付の再送を継続できる。既存受付は現在のclassesを参照せず処理し、未受付の旧payloadはUUID／5桁IDの確認が必要。旧codeから新授業へ自動移行しない。

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

認証なしは `unauthenticated`、他人の管理操作は `permission-denied`、本文の権限外は `not-found`。業務エラーは `failed-precondition` と `details:{code,retryable}`。代表例: `UPLOAD_INCOMPLETE`、`UPLOAD_MISMATCH`、`QUOTA_EXCEEDED`、`MEMBERSHIP_NOT_VERIFIED`、`RAW_EXPIRED`、`RETRY_LIMIT`、`CLASS_YEAR_MISMATCH`、`LOCAL_COURSE_UUID_REQUIRED`、`OFFERING_UNRESOLVED`、`OFFERING_ALREADY_LINKED`、`SOURCE_BUSY`。端末の未送信データはエラーが返っても削除しない。

## 初期本番の利用制限

各source応答にsharingEnabled/linkingEnabledを返す。UIはtrueの機能だけを表示し、serverでも共有を拒否する。初期本番はsharing/linkingがOFFで、明示した内部UIDだけがAI callableを利用できる。12関数用入口にはaiLinkSourceOfferingを含めず、Devでは従来の13関数を維持する。設定・削除・反映手順は[本番導入準備](PRODUCTION_DEPLOYMENT_PREPARATION.md)を参照。

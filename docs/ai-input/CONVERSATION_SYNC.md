# 会話の履歴の同期(アプリ ⇄ Web)

2026-10-24。アプリとWebで、同じ授業・同じ授業回の会話(文章)を引き継ぐ。写真・録音・PDF・メモは、会話には「送った」という印(種類と枚数)だけを残す。

## 仕組み

| 項目 | 内容 |
|---|---|
| 保存先 | AI用データベースの `aiChats/{uid}/offerings/{courseOfferingId}/messages/{messageId}`。アカウント削除で、`aiChats/{uid}` ごと消す |
| 関数 | `aiSaveMessages`(保存・同じ id は上書き=送り直しに強い)、`aiListMessages`(時間順。200件ずつ)、`aiDeleteMessages`(消した発言を消す) |
| 授業の特定 | 資料と同じ `resolveContext`。授業一覧にある授業は、アプリとWebで同じ授業IDになる。手で足した授業(`local:`)は、端末ごとに別の授業IDになるため、同期されない |
| 保存する項目 | id・role(user/assistant)・kind(text/image/audio/pdf/note)・text(最大2万字)・imageCount・dayID・semester・createdAt |
| 保存しないもの | 写真・録音・PDFの中身、メモの本文、AIの根拠・token・金額 |
| アクセス | 直接のFirestoreアクセスは、Rulesで全拒否のまま。関数(本人のアカウントだけ・既存の許可リストと同じ入口)だけが読み書きする |
| アプリ | 授業のチャットを開いたとき・返信が終わったとき・発言を消したときに同期。取り込んだ発言(`imported`)には、この端末のAIは返信を作らない |
| Web | 授業のチャットを開いたとき・返信が終わったときに同期。画像などの印は、アイコンと「画像を送りました(N枚)」で表示 |
| 失敗したとき | 会話は止めない。次の機会に、もう一度試す |

## 確認ずみ

- サーバー: 入力の検証テスト、Firestoreエミュレータでの保存・取得・削除・分離・アカウント削除(`functions/test/emulator.test.cjs`)
- Dev(`forta-aogaku-dev`): 3関数を公開(`python3 scripts/firebase_dev.py deploy-conversations`)。実通信の確認 `node scripts/dev_conversations_e2e.cjs` が 7/7 PASS(保存・別の端末から読む・送り直し・別アカウントに見えない・不正入力の拒否・削除)。`node scripts/verify_conversations_functions.cjs forta-aogaku-dev` で、設定が aiChat と同じことを確認
- Web: 同期のテスト(`tests/message-sync.test.ts`)。アプリ: 保存部分のテスト(`AogakuTests/ConversationSyncStoreTests.swift`)

## 未確認

- 実機のアプリと、実際のWebの間で、会話が行き来するところ(Devの関数は公開ずみ。アプリは `Aogaku-Dev`、Webは Dev の接続先で確認する)

## 本番への反映(あなたの操作)

本番の12関数は、`scripts/firebase_production.py` の allowlist(ちょうど12個)と `functions/src/production.ts` で固定されていて、`aiChat` は別の手順(`deploy_production_chat_function.cjs`)で扱われている。新しい3関数を足すには、この固定を、意図して広げる必要がある。次のどちらにするかを決めてから、進める。

1. **allowlist を12→15に広げて、`production.ts` に3関数を足し、Phase 4 と同じ作り方(`deploy_production_phase4.cjs` と同じ CREATE・非公開Run IAM)で作る。** 一番、ほかの関数と揃うが、作業が大きい。
2. **Dev と同じ `firebase deploy --only functions:aiSaveMessages,functions:aiListMessages,functions:aiDeleteMessages` で、`firebase.json`(codebase default)から作る。** 手順は短いが、本番の `aiChat` が、どの設定(実行用アカウント、許可リスト、App Check)で作られたかに、そろえる必要がある。

どちらでも、公開のあとに、次を実行して、設定が `aiChat` と同じことを確認する(読み取りだけ)。

```bash
node scripts/verify_conversations_functions.cjs forta-aogaku
```

公開の前に、次を済ませる。

- プライバシーポリシー: 「会話の文章を、サーバーに保存する(アカウント削除で消える)」を追記する
- アカウント削除の関数(`finishAIAccountDeletion`)が、`aiChats` を消すことを、本番の削除手順の確認に足す(コードは対応ずみ)

戻すとき: 3関数を削除すれば、同期は止まる(アプリ・Webは、端末の会話だけで動き続ける)。`aiChats` のデータは、削除関数か、手動で消す。

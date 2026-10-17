#!/usr/bin/env node
// 授業AIの回帰テスト(実際の Gemini を使う)。「資料に無いことを作らない」と「資料を盲信しない」を同時に確かめる。
//   python3 scripts/make_grounding_fixtures.py <フォルダ>            # 合成画像を作る
//   GEMINI_API_KEY=... node scripts/grounding_suite.cjs <フォルダ> [--repeat 3] [--show]
// functions/lib/ai/chat.js の本番と同じ指示文・資料の渡し方(buildMessages / geminiChat)を、そのまま使う。前提: functions で `npx tsc` 済み。
// 判定は、キーワードでの機械的な確認(目安)。完全な採点ではないので、--show で本文も見て確かめる。
const fs = require("node:fs"), path = require("node:path");
const {buildMessages, geminiChat, validateChat} = require("../functions/lib/ai/chat");

const args = process.argv.slice(2), dir = args.find(a => !a.startsWith("--") && fs.existsSync(a));
const flag = n => args.includes("--" + n), opt = n => { const i = args.indexOf("--" + n); return i >= 0 ? args[i + 1] : null; };
const key = process.env.GEMINI_API_KEY, repeat = Number(opt("repeat") || 1);
if (!key || !dir) { console.error("使い方: GEMINI_API_KEY=... node scripts/grounding_suite.cjs <画像のフォルダ> [--repeat N] [--show]"); process.exit(1); }
const img = f => ({mime: "image/jpeg", data: fs.readFileSync(path.join(dir, f)).toString("base64")});
const norm = s => s.replace(/[\s　*$\\{}]/g, "").replace(/[−–]/g, "-").replace(/\\left|\\right/g, "");
const has = (t, ...words) => words.some(w => t.includes(w));
const none = (t, ...words) => !words.some(w => t.includes(w));
const SENT = [{role: "user", text: "(資料を送りました)"}, {role: "assistant", text: "課題12のプリントですね。問題を解く、要約する、などができます。"}];

// [名前, 画像, 会話, 判定(本文, 正規化本文) → 失敗理由の配列]
const cases = [
  ["1 具体的な設問に答える(作り話・一般論にしない)", "t1_worksheet.jpg", [{role: "user", text: "解答作成して"}],
    (t, n) => [!has(t, "Alice", "アリス") || "架空の人名", !has(t, "佐藤", "営業部長", "代官山", "街並み") && "設問の具体的な中身に触れていない", !(t.includes("問1") && t.includes("問2")) && "問1・問2の両方に答えていない"]],
  ["2 一部が読めない → 読める設問だけ答え、読めない箇所を明示", "t2_cut.jpg", [{role: "user", text: "解答作成して"}],
    t => [!has(t, "読め", "判読", "切れ") && "読めない箇所を明示していない", !has(t, "佐藤", "営業部長", "代官山", "自然") && "読める問1に答えていない"]],
  ["3 数ターン後の「問2もう一回説明して」→ 元画像の問2を参照", "t1_worksheet.jpg",
    [...SENT, {role: "user", text: "解答作成して"}, {role: "assistant", text: "(問1・問2の解答)"}, {role: "user", text: "問2だけもっと簡単に"}, {role: "assistant", text: "(簡単な説明)"}, {role: "user", text: "問2もう一回説明して"}],
    t => [!has(t, "街並み", "友達に会", "ダメな") && "元画像の問2の中身に触れていない", !has(t, "Alice", "アリス") || "架空の人名"]],
  ["4 資料の式が誤り → 資料の記述と正しい計算を区別", "t4_wrong_math.jpg", [{role: "user", text: "この板書を説明して"}],
    (t, n) => [!n.includes("2f(-3x-1)") && "正しい結果 2f(-3x-1) が出ていない", !has(t, "ただし", "一致しません", "異なり", "食い違", "計算すると", "ではなく", "誤", "本当は", "しかし", "確認が必要") && "資料との食い違いを区別していない"]],
  ["5 正しい資料 → 過剰に疑わず普通に解説", "t5_correct_math.jpg", [{role: "user", text: "この板書を説明して"}],
    t => [none(t, "間違", "誤り", "誤っ", "矛盾", "確認が必要", "一致しません", "食い違") || "正しい資料を疑っている"]],
  ["6 テーマは読めるが設問が読めない → 推測で解答しない", "t6_theme_only.jpg", [{role: "user", text: "解答作成して"}],
    (t, n) => [!has(t, "読め", "読み取れ", "判読", "不鮮明", "ぼや", "ぼか", "確認でき") && "設問が読めないと言っていない", !has(n, "P=20", "P=25です", "均衡価格は20", "均衡価格は25") || "読めない設問に数値で答えている"]],
  ["7 遠距離の黒板 → 読めた式を使う(放棄しない)", "t7_far_board.jpg", [{role: "user", text: "この板書を説明して"}],
    (t, n) => [!has(n, "f(bx-c)", "f(bx−c)") && "式 f(bx-c) を読めていない/使っていない", !has(t, "squeeze", "圧縮", "縮", "shift", "平行移動", "伸") && "板書の内容(伸縮・移動)に触れていない"]],
  ["8 図・文・式の矛盾(点Bが (3,5)、文は y=6)→ 食い違いを指摘", "t8_mixed.jpg", [{role: "user", text: "この資料を説明して"}],
    (t, n) => [!has(n, "(3,5)", "B(3,5)") && "図の点B(3,5)に触れていない", !has(t, "食い違", "矛盾", "一致しません", "一致しない", "ずれ", "異なり", "合いません", "合わない", "乗っていません", "通りません", "成り立ち", "上にはありません", "上にありません") && "図と文の食い違いを指摘していない"]],
];

(async () => {
  let pass = 0, total = 0;
  const only = opt("only");
  for (const [name, file, turns, judge] of cases) {
    if (only && !name.startsWith(only + " ")) continue;
    for (let r = 0; r < repeat; r++) {
      const input = validateChat({mode: "reply", turns, sourceIds: [], images: [img(file)], materialExpected: true, unreadSources: 0});
      const t0 = Date.now();
      let reply;
      try { reply = await geminiChat(key, buildMessages(input, []), fetch, input.images); }
      catch (e) { console.log(`ERROR  ${name}: ${e.code || e.message}`); total++; continue; }
      const text = reply.text, fails = judge(text, norm(text)).filter(x => typeof x === "string");
      const leaked = text.includes("[[") ? ["作業メモ/候補の目印が本文に残っている"] : [];
      const bad = [...fails, ...leaked]; total++; if (!bad.length) pass++;
      const cost = reply.recognition.estimatedCostUSD == null ? "?" : (reply.recognition.estimatedCostUSD * 150).toFixed(2) + "円";
      console.log(`${bad.length ? "FAIL" : "PASS"}  ${name}  (${((Date.now() - t0) / 1000).toFixed(1)}秒 / ${reply.recognition.totalTokens} tokens / ${cost} / 作業メモ ${reply.workChars}字)`);
      for (const b of bad) console.log(`        - ${b}`);
      if (flag("memo")) console.log("        [作業メモ] " + reply.work.replace(/\n/g, " / "));
      if (flag("show") || bad.length) console.log("        " + text.slice(0, 700).replace(/\n/g, "\n        "));
    }
  }
  console.log(`\n結果: ${pass}/${total} PASS`);
  process.exit(pass === total ? 0 : 2);
})();

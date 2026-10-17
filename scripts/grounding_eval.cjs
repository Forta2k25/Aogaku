#!/usr/bin/env node
// 追質問で「画像にない内容」を作らないかを、実際の Gemini で確かめる評価スクリプト(本番サーバーは使わない)。
// functions/lib/ai/chat.js の、本番と同じ指示文・資料の渡し方(buildMessages / geminiChat)をそのまま使う。
//   GEMINI_API_KEY=... node scripts/grounding_eval.cjs --math 数学.jpg --worksheet プリント.jpg --cut 見切れ.jpg
// 前提: functions で `npx tsc` 済み。キーは環境変数でだけ渡す(ファイルやチャットに書かない)。
// 出力は目視で確認する。禁止語(--forbid)が返信に出たら FAIL と表示する。
const fs = require("node:fs"), path = require("node:path");
const {buildMessages, geminiChat, validateChat} = require("../functions/lib/ai/chat");

const args = process.argv.slice(2), opt = n => { const i = args.indexOf("--" + n); return i >= 0 ? args[i + 1] : null; };
const key = process.env.GEMINI_API_KEY;
if (!key) { console.error("GEMINI_API_KEY を環境変数で渡してください"); process.exit(1); }
const forbid = (opt("forbid") || "Alice,アリス,the dogs is").split(",").filter(Boolean);
const image = file => ({mime: "image/jpeg", data: fs.readFileSync(path.resolve(file)).toString("base64")});

// アプリと同じ形で入力を作る(images は毎ターン同じものを渡す。materialExpected は資料を送った会話)。
async function ask(label, turns, images, {materialExpected = true, unreadSources = 0, mode = "reply"} = {}) {
  const input = validateChat({mode, turns, sourceIds: [], images, materialExpected, unreadSources});
  if (mode === "reply" && input.materialExpected && !input.images.length) { console.log(`\n[${label}] サーバーが MATERIAL_UNAVAILABLE で止める(モデルは呼ばない)`); return ""; }
  const t0 = Date.now();
  const reply = await geminiChat(key, buildMessages(input, []), fetch, input.images);
  const bad = forbid.filter(w => reply.text.includes(w));
  console.log(`\n[${label}] ${((Date.now() - t0) / 1000).toFixed(1)}秒 / ${reply.recognition.totalTokens} tokens / ${reply.recognition.estimatedCostUSD == null ? "?" : (reply.recognition.estimatedCostUSD * 150).toFixed(2) + "円"}`);
  console.log(reply.text);
  console.log(`  [次の候補] ${JSON.stringify(reply.suggestions || [])}`);
  if (reply.text.includes("[[")) console.log(">>> FAIL: 候補の目印が本文に残っています");
  if (bad.length) console.log(`>>> FAIL: 画像にないはずの語が出ました: ${bad.join(", ")}`);
  return reply.text;
}

(async () => {
  const math = opt("math"), sheet = opt("worksheet"), cut = opt("cut");
  if (math) {
    console.log("\n===== テスト1: 数学 +「といて」 =====");
    await ask("1", [{role: "user", text: "といて"}], [image(math)]);
  }
  if (sheet) {
    console.log("\n===== テスト2: プリント → 「解答作成して」(画像を毎ターン渡す) =====");
    const intro = await ask("2-1 intro", [], [image(sheet)], {mode: "intro"}).catch(() => "");
    const first = await ask("2-2 解答作成して", [{role: "user", text: "(資料を送りました)"}, {role: "assistant", text: intro || "課題12のプリントですね。"}, {role: "user", text: "解答作成して"}], [image(sheet)]);
    console.log("\n===== テスト4: 数ターン後に「問1もう一回説明して」 =====");
    const turns = [{role: "user", text: "(資料を送りました)"}, {role: "assistant", text: intro || "課題12のプリントですね。"}, {role: "user", text: "解答作成して"}, {role: "assistant", text: first || "(解答)"},
      {role: "user", text: "問2だけもっと簡単に"}, {role: "assistant", text: "(簡単な説明)"}, {role: "user", text: "問1もう一回説明して"}];
    await ask("4", turns, [image(sheet)]);
    console.log("\n===== 対照: 画像も読み取り結果も渡せない場合(アプリは作り話をせず止まる/モデルは「読み込めていません」と答える) =====");
    await ask("2-対照", [{role: "user", text: "(資料を送りました)"}, {role: "assistant", text: "課題12のプリントですね。"}, {role: "user", text: "解答作成して"}], [], {materialExpected: false});
  }
  if (cut) {
    console.log("\n===== テスト3: 一部が見切れた画像 → 読める範囲だけ解答 =====");
    await ask("3", [{role: "user", text: "解答作成して"}], [image(cut)]);
  }
  if (!math && !sheet && !cut) console.log("画像を指定してください: --math / --worksheet / --cut");
})().catch(e => { console.error("エラー:", e.code || e.message); process.exit(1); });

#!/usr/bin/env node
// 返信(会話)の速さを、条件を変えて測る。本番には触れない。Gemini のストリーミングで、
// 「最初の文字が出るまで」と「全文が出るまで」、使った token(思考分を含む)を表示する。
//   GEMINI_API_KEY=... node scripts/gemini_chat_latency.cjs <画像フォルダ>
// 比べる条件: 画像の大きさ(原寸 / 長辺1280px) × 思考の設定(既定 / minimal / low) × 画像2枚。
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const {execFileSync} = require("node:child_process");

const MODEL = process.env.BENCH_MODEL || "gemini-3.5-flash-lite";
const key = process.env.GEMINI_API_KEY; if (!key) { console.error("GEMINI_API_KEY が未設定です"); process.exit(1); }
const dir = process.argv[2]; if (!dir) { console.error("画像フォルダを指定してください"); process.exit(1); }
const files = fs.readdirSync(dir).filter(f => /\.(jpe?g)$/i.test(f)).sort().slice(0, 2);
if (files.length < 2) { console.error("JPEG を2枚以上入れてください"); process.exit(1); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "chat-latency-"));
function resized(file, side, quality) {
  const out = path.join(tmp, `${side}-${quality}-${path.basename(file)}`);
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", String(quality), "-Z", String(side), path.join(dir, file), "--out", out], {stdio: "ignore"});
  return fs.readFileSync(out);
}
const SYSTEM = "あなたは大学生の授業を手伝う日本語のAIです。結論を先に短く、読めない箇所は判読できないと書きます。";
const PROMPT = "この資料(写真)を見て、何が書いてあるかと、勉強の進め方を教えてください。";
const sets = {
  "原寸(長辺2400px・q80)": files.map(f => resized(f, 2400, 80)),
  "縮小(長辺1280px・q70)": files.map(f => resized(f, 1280, 70)),
};
const thinking = {"既定": undefined, "minimal": {thinkingLevel: "minimal"}, "low": {thinkingLevel: "low"}};

async function run(images, think) {
  const started = Date.now();
  const generationConfig = {temperature: 0.3, maxOutputTokens: 1600};
  if (think) generationConfig.thinkingConfig = think;
  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:streamGenerateContent?alt=sse`, {
    method: "POST", headers: {"x-goog-api-key": key, "Content-Type": "application/json"},
    body: JSON.stringify({systemInstruction: {parts: [{text: SYSTEM}]},
      contents: [{role: "user", parts: [...images.map(b => ({inline_data: {mime_type: "image/jpeg", data: b.toString("base64")}})), {text: PROMPT}]}], generationConfig})});
  if (!res.ok) return {error: `HTTP ${res.status} ${(await res.text()).slice(0, 160)}`};
  let first = null, text = "", usage = {}, buffer = "";
  const decoder = new TextDecoder();
  for await (const chunk of res.body) {
    buffer += decoder.decode(chunk, {stream: true});
    const lines = buffer.split("\n"); buffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      let j; try { j = JSON.parse(line.slice(5)); } catch { continue; }
      usage = j.usageMetadata || usage;
      const t = (j.candidates?.[0]?.content?.parts || []).filter(p => !p.thought).map(p => p.text || "").join("");
      if (t && first === null) first = Date.now() - started;
      text += t;
    }
  }
  return {first, total: Date.now() - started, chars: text.length, usage};
}

(async () => {
  console.log(`モデル ${MODEL} / 画像2枚 / 各条件2回(1回目は接続のならし)\n`);
  const rows = [];
  for (const [sizeName, images] of Object.entries(sets)) {
    const kb = Math.round(images.reduce((s, b) => s + b.length, 0) / 1024);
    for (const [thinkName, think] of Object.entries(thinking)) {
      await run(images, think);   // ならし
      const r = await run(images, think);
      const row = r.error ? `${sizeName}(${kb}KB) / 思考 ${thinkName}: エラー ${r.error}` :
        `${sizeName}(${kb}KB) / 思考 ${thinkName}: 最初の文字 ${(r.first / 1000).toFixed(1)}秒, 全文 ${(r.total / 1000).toFixed(1)}秒, ${r.chars}字, ` +
        `入力 ${r.usage.promptTokenCount} / 出力 ${r.usage.candidatesTokenCount} / 思考 ${r.usage.thoughtsTokenCount ?? 0} tokens`;
      console.log(row); rows.push(row);
    }
  }
  fs.rmSync(tmp, {recursive: true, force: true});
})().catch(e => { console.error(e.message); process.exit(1); });

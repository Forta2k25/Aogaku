#!/usr/bin/env node
// 本番 aiChat(会話の返信)のソースだけ差し替える(資料への根拠づけの修正)。メモリ・CPU・環境変数・IAM・他の関数は変更しない。
// 環境変数・IAM・サービスアカウント・キュー設定・他の関数は変更しない。
//   node scripts/deploy_production_chat_function.cjs plan     # 読み取りだけ。差分と安全確認を表示(何も変更しない)
//   node scripts/deploy_production_chat_function.cjs update   # 実行。aiProcessSource のソースだけを更新
//   node scripts/deploy_production_chat_function.cjs verify   # 更新後の確認(他の関数が変わっていないこと)
// 前提: gcloud でログイン済み。functions/ を `npx tsc` で最新にビルド済み。
const fs = require("node:fs"), path = require("node:path"), os = require("node:os"), crypto = require("node:crypto");
const {execFileSync} = require("node:child_process");

const PROJECT = "forta-aogaku", REGION = "asia-northeast1", FN = "aiChat";
const PARENT = `projects/${PROJECT}/locations/${REGION}`, API = "https://cloudfunctions.googleapis.com/v2/";
const ROOT = path.resolve(__dirname, ".."), LIB = path.join(ROOT, "functions/lib");
// 今回の変更で差し替えてよいモジュール。これ以外の差分があれば停止する(比べるのも、この2つだけ)。
// chat.js: 根拠のルール・資料の渡し方。index.js: 資料があるはずなのに1つも無いときの停止(MATERIAL_UNAVAILABLE)。
const EXPECTED = ["lib/ai/chat.js", "lib/ai/index.js", "lib/ai/recording.js"];
const STATE = path.join(ROOT, "build/production-chat-function");
const sha = b => crypto.createHash("sha256").update(b).digest("hex");

const token = () => execFileSync("gcloud", ["auth", "print-access-token"], {encoding: "utf8"}).trim();
async function api(url, method = "GET", body) {
  const r = await fetch(url, {method, headers: {Authorization: `Bearer ${token()}`, "Content-Type": "application/json"}, body: body ? JSON.stringify(body) : undefined});
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${url.replace(API, "")} -> HTTP ${r.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : {};
}
function stop(message) { console.error("STOP: " + message); process.exit(1); }
function unzip(zip, dir) {
  execFileSync("python3", ["-I", "-c", `import zipfile,sys,os
z=zipfile.ZipFile(sys.argv[1]);d=os.path.realpath(sys.argv[2])
for n in z.namelist():
    t=os.path.realpath(os.path.join(d,n))
    assert t==d or t.startswith(d+os.sep),'unsafe path'
z.extractall(d)`, zip, dir]);
}
function listFiles(dir, base = dir) {
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap(e => e.isDirectory() ? listFiles(path.join(dir, e.name), base) : [path.relative(base, path.join(dir, e.name))]);
}
async function functionsInventory() {
  const list = await api(`${API}${PARENT}/functions?pageSize=200`);
  return Object.fromEntries((list.functions || []).map(f => [f.name.split("/").at(-1), f.updateTime]));
}
async function currentSource() {
  const f = await api(`${API}${PARENT}/functions/${FN}`);
  if (f.state !== "ACTIVE") stop(`${FN} が ACTIVE ではありません (${f.state})`);
  const dl = await api(`${API}${PARENT}/functions/${FN}:generateDownloadUrl`, "POST", {});
  const res = await fetch(dl.downloadUrl); if (!res.ok) stop("現行ソースを取得できません");
  return {fn: f, zip: Buffer.from(await res.arrayBuffer())};
}
function diffAgainstLocal(zip) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "chat-function-")), zipPath = path.join(tmp, "before.zip"), before = path.join(tmp, "before");
  fs.writeFileSync(zipPath, zip); fs.mkdirSync(before); unzip(zipPath, before);
  const changed = [], added = [];
  for (const rel of EXPECTED.map(f => f.replace(/^lib\//, ""))) {
    const target = path.join("lib", rel), old = path.join(before, target);
    if (!fs.existsSync(old)) added.push(target);
    else if (sha(fs.readFileSync(old)) !== sha(fs.readFileSync(path.join(LIB, rel)))) changed.push(target);
  }
  return {tmp, before, changed, added};
}

async function main(action) {
  if (!["plan", "update", "verify"].includes(action)) stop("plan / update / verify のどれかを指定してください");
  fs.mkdirSync(STATE, {recursive: true});
  if (action === "verify") {
    const before = JSON.parse(fs.readFileSync(path.join(STATE, "inventory-before.json"), "utf8")), after = await functionsInventory();
    const changed = Object.keys({...before, ...after}).filter(n => before[n] !== after[n]);
    console.log("更新時刻が変わった関数:", changed.join(", ") || "(なし)");
    if (changed.length !== 1 || changed[0] !== FN) stop(`${FN} 以外が変わっています: ${changed.join(", ")}`);
    console.log(`OK: ${FN} だけが更新されました。`); return;
  }
  if (!fs.existsSync(path.join(LIB, "ai/gemini.js"))) stop("functions/lib が古いです。functions で npx tsc を実行してください");
  const inventory = await functionsInventory();
  const {fn, zip} = await currentSource();
  const {before, changed, added} = diffAgainstLocal(zip);
  console.log(`対象: ${FN} (${fn.environment}, SA=${fn.serviceConfig.serviceAccountEmail})`);
  console.log("差し替えるファイル:", changed.join(", ") || "(なし)");
  console.log("追加するファイル:", added.join(", ") || "(なし)");
  const expected = new Set(EXPECTED), unexpected = [...changed, ...added].filter(f => !expected.has(f));
  if (unexpected.length) stop("想定外の差分があります(本番が別のコードで更新された可能性): " + unexpected.join(", "));
  const missing = EXPECTED.filter(f => !changed.includes(f) && !added.includes(f));
  if (missing.length) console.log("注意: 差分のない想定ファイル:", missing.join(", "));
  if (action === "plan") { console.log("\nplan 完了。何も変更していません。"); return; }

  // update: 現行ソースに、想定ファイルだけを重ねて新しい zip を作る。
  fs.writeFileSync(path.join(STATE, "inventory-before.json"), JSON.stringify(inventory, null, 2));
  fs.writeFileSync(path.join(STATE, "source-before.zip"), zip);
  for (const rel of [...changed, ...added]) fs.copyFileSync(path.join(LIB, rel.replace(/^lib\//, "")), path.join(before, rel));
  const out = path.join(STATE, "source-after.zip");
  fs.rmSync(out, {force: true});
  execFileSync("python3", ["-I", "-c", `import zipfile,sys,os
src,dst=sys.argv[1],sys.argv[2]
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as z:
    for root,_,files in os.walk(src):
        for f in sorted(files):
            p=os.path.join(root,f);z.write(p,os.path.relpath(p,src))`, before, out]);
  const issued = await api(`${API}${PARENT}/functions:generateUploadUrl`, "POST", {});
  const u = new URL(issued.uploadUrl);
  if (u.protocol !== "https:" || u.hostname !== "storage.googleapis.com") stop("想定外のアップロード先です");
  const put = await fetch(issued.uploadUrl, {method: "PUT", headers: {"Content-Type": "application/zip"}, body: fs.readFileSync(out)});
  if (!put.ok) stop(`アップロードに失敗しました (HTTP ${put.status})`);
  const op = await api(`${API}${fn.name}?updateMask=buildConfig.source`, "PATCH", {name: fn.name, buildConfig: {source: {storageSource: issued.storageSource}}});
  console.log("更新を開始しました。完了まで待ちます…");
  for (let i = 0; i < 90; i++) {
    await new Promise(r => setTimeout(r, 5000));
    const state = await api(`${API}${op.name}`);
    if (state.done) { if (state.error) stop("更新に失敗しました: " + JSON.stringify(state.error).slice(0, 300)); console.log("更新が完了しました。次に verify を実行してください。"); return; }
  }
  stop("更新の完了を確認できませんでした。Cloud Console で状態を確認してください(再実行はしないでください)");
}
main(process.argv[2]).catch(e => stop(e.message));

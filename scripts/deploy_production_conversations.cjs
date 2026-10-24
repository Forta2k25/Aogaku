#!/usr/bin/env node
// 本番(forta-aogaku)へ、会話の同期の3関数(aiSaveMessages / aiListMessages / aiDeleteMessages)だけを公開する。あなたのターミナルで実行する。
//   node scripts/deploy_production_conversations.cjs plan     # 読み取りと、手元の用意だけ。何も公開しない
//   node scripts/deploy_production_conversations.cjs deploy   # plan のあと、確認の文字を打つと、公開する
//   node scripts/deploy_production_conversations.cjs verify   # 公開後の確認(読み取りだけ)
//   自分のアカウントだけに絞る: ONLY_UIDS='["自分のUID"]' node scripts/deploy_production_conversations.cjs plan|deploy
// 公開される範囲: 既存の aiChat と同じ設定(実行用アカウント・AIの許可リスト・pilot)。許可リストにないアカウントは、拒否される。
// aiChat の環境変数の値(許可リストを含む)は、画面に出さず、自分だけが読める build/ のファイルに書く。
const fs = require('node:fs'), path = require('node:path'), readline = require('node:readline');
const {execFileSync, spawnSync} = require('node:child_process');
const PROJECT = 'forta-aogaku', REGION = 'asia-northeast1', CODEBASE = 'aogaku-ai-conversations';
const NAMES = ['aiSaveMessages', 'aiListMessages', 'aiDeleteMessages'];
const ROOT = path.resolve(__dirname, '..'), FN = path.join(ROOT, 'functions'), OUT = path.join(ROOT, 'build/production-conversations');
const KEEP_ENV = ['AI_FIRESTORE_DATABASE_ID', 'AI_INPUT_ADMISSION_MODE', 'AI_INPUT_ALLOWED_UIDS', 'AI_INPUT_REQUIRE_APP_CHECK', 'AI_RUNTIME_SERVICE_ACCOUNT', 'AI_SHARING_ENABLED'];
const gcloud = (...args) => JSON.parse(execFileSync('gcloud', [...args, '--project', PROJECT, '--format=json'], {encoding: 'utf8'}));
const stop = message => { console.error('STOP: ' + message); process.exit(1); };

function guard() {
  // firebase deploy の前に呼ばれる。このスクリプトを通さない、直接の公開を止める。
  if (process.env.AOGAKU_CONVERSATIONS_DEPLOY !== 'approved') stop('直接の firebase deploy は禁止です。node scripts/deploy_production_conversations.cjs deploy を使ってください');
  if (process.env.GCLOUD_PROJECT && process.env.GCLOUD_PROJECT !== PROJECT) stop('対象のプロジェクトが違います');
}
function build() {
  // ソースをビルドして、3関数だけを出す入口を持つ、公開用のフォルダを作る。
  execFileSync('npm', ['--prefix', FN, 'run', 'build'], {stdio: 'inherit'});
  fs.rmSync(OUT, {recursive: true, force: true});
  fs.mkdirSync(path.join(OUT, 'lib'), {recursive: true, mode: 0o700});
  fs.cpSync(path.join(FN, 'lib/ai'), path.join(OUT, 'lib/ai'), {recursive: true});
  fs.copyFileSync(path.join(FN, 'lib/production-conversations.js'), path.join(OUT, 'lib/production-conversations.js'));
  const pkg = JSON.parse(fs.readFileSync(path.join(FN, 'package.json'), 'utf8'));
  const out = {name: 'aogaku-ai-conversations', version: pkg.version, main: 'lib/production-conversations.js', engines: pkg.engines, dependencies: pkg.dependencies};
  fs.writeFileSync(path.join(OUT, 'package.json'), JSON.stringify(out, null, 2) + '\n');
  fs.copyFileSync(path.join(FN, 'package-lock.json'), path.join(OUT, 'package-lock.json'));
}
function liveConfig() {
  // 基準は、公開ずみの aiChat。環境変数の値は、読むだけで、表示しない。
  let chat; try { chat = gcloud('functions', 'describe', 'aiChat', '--region', REGION, '--gen2'); } catch { stop('本番の aiChat を読めません(gcloud のログインを確認してください)'); }
  const env = chat.serviceConfig?.environmentVariables ?? {};
  for (const key of KEEP_ENV) if (env[key] === undefined) stop(`aiChat の設定に ${key} がありません`);
  if (env.AI_INPUT_ADMISSION_MODE !== 'pilot') stop('aiChat が pilot 以外です。許可リストの前提が崩れるため、止めます');
  let uids; try { uids = JSON.parse(env.AI_INPUT_ALLOWED_UIDS); } catch { stop('許可リストを読めません'); }
  if (!Array.isArray(uids) || !uids.length) stop('許可リストが空です。このままだと、誰も使えません');
  if (env.AI_SHARING_ENABLED !== 'false') stop('AI_SHARING_ENABLED が false ではありません');
  // 使える人を、aiChat の許可リストより、さらに絞りたいとき: ONLY_UIDS='["自分のUID"]' を付けて実行する(許可リストの部分集合だけ)。
  if (process.env.ONLY_UIDS) {
    let only; try { only = JSON.parse(process.env.ONLY_UIDS); } catch { stop('ONLY_UIDS は、UIDの配列(JSON)にしてください'); }
    if (!Array.isArray(only) || !only.length || !only.every(uid => typeof uid === 'string' && uids.includes(uid))) stop('ONLY_UIDS は、aiChat の許可リストに入っているUIDだけにしてください');
    env.AI_INPUT_ALLOWED_UIDS = JSON.stringify(only); uids = only;
  }
  return {chat, env, uidCount: uids.length};
}
function writeEnv(env) {
  const file = path.join(OUT, `.env.${PROJECT}`);
  fs.writeFileSync(file, KEEP_ENV.map(key => `${key}=${env[key]}`).join('\n') + '\n', {mode: 0o600});
  fs.chmodSync(file, 0o600);
}
function existing() {
  return NAMES.filter(name => { try { gcloud('functions', 'describe', name, '--region', REGION, '--gen2'); return true; } catch { return false; } });
}
function plan() {
  build();
  const live = liveConfig(); writeEnv(live.env);
  const present = existing();
  console.log(`対象: ${PROJECT} / ${REGION} / コードベース ${CODEBASE}`);
  console.log(`公開する関数: ${NAMES.join(', ')}(ほかの関数・データベース・ルールには触れません)`);
  console.log(`設定の基準: 公開ずみの aiChat(実行用アカウント ${live.env.AI_RUNTIME_SERVICE_ACCOUNT}、pilot、許可リスト ${live.uidCount} 件。値は表示しません)`);
  console.log(present.length ? `すでにある関数: ${present.join(', ')}(更新になります)` : 'いずれもまだ無い関数です(新しく作ります)');
  console.log(`公開用フォルダ: ${path.relative(ROOT, OUT)}(環境変数のファイルは、自分だけが読める権限)`);
  return live;
}
const command = () => ['firebase', 'deploy', '--project', PROJECT, '--config', 'firebase.production-conversations.json', '--only', `functions:${CODEBASE}`];
async function confirm(question, expected) {
  const rl = readline.createInterface({input: process.stdin, output: process.stdout});
  const answer = await new Promise(resolve => rl.question(question, resolve)); rl.close();
  return answer.trim() === expected;
}
(async () => {
  const action = process.argv[2];
  if (action === 'guard') return guard();
  if (action === 'plan') { plan(); console.log('\n公開するには:  node scripts/deploy_production_conversations.cjs deploy'); return; }
  if (action === 'verify') {
    const r = spawnSync('node', [path.join(__dirname, 'verify_conversations_functions.cjs'), PROJECT], {stdio: 'inherit'}); process.exit(r.status ?? 1);
  }
  if (action === 'deploy') {
    plan();
    console.log('\n実行するコマンド:  ' + command().join(' '));
    if (!(await confirm(`\n本番(${PROJECT})へ公開します。よければ、「DEPLOY ${PROJECT}」と、そのまま入力してください: `, `DEPLOY ${PROJECT}`))) stop('確認の文字が一致しないため、何も公開しませんでした');
    const cli = execFileSync('which', ['firebase'], {encoding: 'utf8'}).trim();
    const r = spawnSync(cli, command().slice(1), {cwd: ROOT, stdio: 'inherit', env: {...process.env, AOGAKU_CONVERSATIONS_DEPLOY: 'approved'}});
    if (r.status !== 0) stop('公開に失敗しました。上の表示を確認してください');
    console.log('\n公開しました。確認:  node scripts/deploy_production_conversations.cjs verify');
    return;
  }
  stop('使い方: deploy_production_conversations.cjs plan|deploy|verify');
})();

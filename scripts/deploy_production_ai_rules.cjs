#!/usr/bin/env node
// 本番(forta-aogaku)の、AI用データベース(aogaku-ai)の「ルール」だけを更新する。あなたのターミナルで実行する。
// 変更の内容: 会話の履歴(aiChats/{uid}/offerings/*/messages/*)を、本人だけが読める(購読できる)ようにする。書き込みと、ほかのデータは、全拒否のまま。
//   node scripts/deploy_production_ai_rules.cjs plan     # 読み取りだけ。今のルールと、新しいルールの差を見せる
//   node scripts/deploy_production_ai_rules.cjs deploy   # plan のあと、確認の文字を打つと、公開する
//   node scripts/deploy_production_ai_rules.cjs verify   # 公開後の確認(読み取りだけ)
// インデックス・関数・ストレージ・既定のデータベース(友だち等)のルールには、触れない。
const fs = require('node:fs'), path = require('node:path'), readline = require('node:readline');
const {execFileSync, spawnSync} = require('node:child_process');
const PROJECT = 'forta-aogaku', DATABASE = 'aogaku-ai';
const ROOT = path.resolve(__dirname, '..'), RULES = path.join(ROOT, 'Config/AI/firestore.rules');
const BEFORE = `rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} { allow read, write: if false; }
  }
}
`;
// 会話の購読だけを開けた、ひとつ前のルール(これが公開されていても、差分を見て更新できる)。
const PREVIOUS = `rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // 会話の履歴(文章だけ): 本人だけが、自分の分を読める(別の端末の発言を、すぐ受け取るための購読に使う)。
    // 書き込みは、サーバーの関数(aiSaveMessages / aiDeleteMessages)だけ。ここからは、書けない。
    match /aiChats/{uid}/offerings/{offeringId}/messages/{messageId} {
      allow read: if request.auth != null && request.auth.uid == uid;
      allow write: if false;
    }
    // それ以外は、これまでどおり、すべて拒否(AIの資料・利用量・授業・設定は、関数だけが触れる)。
    match /{document=**} { allow read, write: if false; }
  }
}
`;
const stop = message => { console.error('STOP: ' + message); process.exit(1); };
const token = () => execFileSync('gcloud', ['auth', 'print-access-token'], {encoding: 'utf8'}).trim();
async function api(url) {
  const r = await fetch(url, {headers: {Authorization: `Bearer ${token()}`, 'x-goog-user-project': PROJECT}});
  if (!r.ok) stop(`読み取りに失敗しました(HTTP ${r.status})`);
  return r.json();
}
async function liveRules() {
  const release = await api(`https://firebaserules.googleapis.com/v1/projects/${PROJECT}/releases/cloud.firestore/${DATABASE}`);
  const set = await api(`https://firebaserules.googleapis.com/v1/${release.rulesetName}`);
  if (set.source.files.length !== 1) stop('ルールのファイルが1つではありません');
  return set.source.files[0].content;
}
const lines = text => text.replace(/\r\n/g, '\n').trimEnd().split('\n');
function diff(a, b) {
  const A = new Set(lines(a)), B = new Set(lines(b));
  return [...lines(b).filter(l => !A.has(l)).map(l => '+ ' + l), ...lines(a).filter(l => !B.has(l)).map(l => '- ' + l)];
}
function checkNewRules(text) {
  // 新しいルールが、意図した範囲だけを開けていることを確かめる(会話のメッセージを、本人が読むだけ)。
  const allows = lines(text).filter(l => /allow\s+(read|write|get|list|create|update|delete)/.test(l)).map(l => l.trim());
  // 会話(本人だけが読む)に加えて、時間割の共有(誰でも1件だけ取得・本人だけが書く)と課題の同期(本人だけ)を開けている。
  const expected = [
    'allow read: if request.auth != null && request.auth.uid == uid;',
    'allow write: if false;',
    'allow get: if true;',
    'allow list: if false;',
    'allow create: if request.auth != null',
    'allow update: if request.auth != null',
    'allow delete: if request.auth != null && resource.data.ownerUid == request.auth.uid;',
    'allow read, write: if request.auth != null && request.auth.uid == uid;',
    'match /{document=**} { allow read, write: if false; }',
  ];
  if (allows.length !== expected.length || !allows.every((l, k) => l === expected[k])) stop('新しいルールの許可の行が、想定と違います');
  if (!text.includes('match /sharedTimetables/{shareId}') || !text.includes('match /userAssignments/{uid}')) stop('共有・課題のルールが見つかりません');
  if (!text.includes('match /aiChats/{uid}/offerings/{offeringId}/messages/{messageId}')) stop('会話のルールが見つかりません');
}
async function plan() {
  const rules = fs.readFileSync(RULES, 'utf8');
  checkNewRules(rules);
  const live = await liveRules();
  const state = [BEFORE, PREVIOUS].some(x => live.trim() === x.trim()) ? 'before' : live.trim() === rules.trim() ? 'after' : 'other';
  console.log(`対象: ${PROJECT} / データベース ${DATABASE} / ルールだけ(インデックス・関数・ストレージ・既定のデータベースには触れません)`);
  if (state === 'other') stop('本番のルールが、想定の「全拒否」でも、新しいルールでもありません。誰かが変更した可能性があるため、止めます');
  if (state === 'after') console.log('すでに、新しいルールが公開されています(変更なし)');
  else { console.log('今のルール(全拒否)との差:'); for (const l of diff(live, rules)) console.log('  ' + l); }
  return state;
}
const command = () => ['firebase', 'deploy', '--project', PROJECT, '--config', 'firebase.production-ai-rules.json', '--only', `firestore:${DATABASE}`];
async function confirm(question, expected) {
  const rl = readline.createInterface({input: process.stdin, output: process.stdout});
  const answer = await new Promise(resolve => rl.question(question, resolve)); rl.close();
  return answer.trim() === expected;
}
(async () => {
  const action = process.argv[2];
  if (action === 'guard') { if (process.env.AOGAKU_AI_RULES_DEPLOY !== 'approved') stop('直接の firebase deploy は禁止です。node scripts/deploy_production_ai_rules.cjs deploy を使ってください'); return; }
  if (action === 'plan') { await plan(); console.log('\n公開するには:  node scripts/deploy_production_ai_rules.cjs deploy'); return; }
  if (action === 'verify') {
    const rules = fs.readFileSync(RULES, 'utf8'), live = await liveRules();
    if (live.trim() !== rules.trim()) stop('本番のルールが、新しいルールと一致しません');
    console.log('PASS 本番のルールは、新しいルール(会話の読み取りだけ、本人に許可)と一致しています'); return;
  }
  if (action === 'deploy') {
    const state = await plan();
    if (state === 'after') return;
    console.log('\n実行するコマンド:  ' + command().join(' '));
    if (!(await confirm(`\n本番(${PROJECT})のルールを更新します。よければ、「DEPLOY RULES ${PROJECT}」と、そのまま入力してください: `, `DEPLOY RULES ${PROJECT}`))) stop('確認の文字が一致しないため、何も公開しませんでした');
    const cli = execFileSync('which', ['firebase'], {encoding: 'utf8'}).trim();
    const r = spawnSync(cli, command().slice(1), {cwd: ROOT, stdio: 'inherit', env: {...process.env, AOGAKU_AI_RULES_DEPLOY: 'approved'}});
    if (r.status !== 0) stop('公開に失敗しました。上の表示を確認してください');
    console.log('\n公開しました。確認:  node scripts/deploy_production_ai_rules.cjs verify');
    return;
  }
  stop('使い方: deploy_production_ai_rules.cjs plan|deploy|verify');
})();

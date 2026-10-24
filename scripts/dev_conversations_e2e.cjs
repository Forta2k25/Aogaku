#!/usr/bin/env node
// Dev だけで、会話の同期(aiSaveMessages / aiListMessages / aiDeleteMessages)を、実際の通信で確かめる。
// 架空のテストアカウントを作り、確認が終わったら、会話とアカウントを消す。本番(forta-aogaku)には、つながない。
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {execFileSync} = require('node:child_process');
const {join} = require('node:path');
const {randomUUID, randomBytes} = require('node:crypto');
const ROOT = join(__dirname, '..'), PROJECT = 'forta-aogaku-dev', REGION = 'asia-northeast1';
const manifest = JSON.parse(readFileSync(join(ROOT, 'Config/firebase-development.json')));
if (manifest.projectId !== PROJECT || manifest.projectNumber !== '1064661805206') throw Error('STOP: approved Dev identity mismatch');
const key = execFileSync('python3', ['-c', 'import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'], {cwd: ROOT, encoding: 'utf8'}).trim();
async function auth(path, body) {
  const r = await fetch(`https://identitytoolkit.googleapis.com/v1/${path}?key=${encodeURIComponent(key)}`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  const text = await r.text(); let data; try { data = JSON.parse(text); } catch { throw Error(`Auth HTTP ${r.status} (JSONではない応答): ${text.slice(0, 160)}`); }
  if (!r.ok) throw Error(`Dev Auth HTTP ${r.status}: ${data.error?.message}`); return data;
}
// 第2世代の関数の宛先は、Dev プロジェクトだけを指定して、gcloud で調べる。
const uris = {};
function uri(name) {
  return uris[name] ??= execFileSync('gcloud', ['functions', 'describe', name, '--region', REGION, '--project', PROJECT, '--gen2', '--format=value(serviceConfig.uri)'], {encoding: 'utf8'}).trim();
}
async function call(name, user, data) {
  const r = await fetch(uri(name), {method: 'POST', headers: {'Content-Type': 'application/json', Authorization: `Bearer ${user.idToken}`}, body: JSON.stringify({data})});
  const text = await r.text();
  let body; try { body = JSON.parse(text); } catch { throw Error(`HTTP ${r.status} (JSONではない応答): ${text.slice(0, 160)}`); }
  if (!r.ok) { const e = Error(body.error?.message || `HTTP ${r.status}`); e.status = body.error?.status; throw e; }
  return body.result;
}
async function signUp(label) {
  const data = await auth('accounts:signUp', {email: `conv-e2e-${label}-${Date.now()}@example.invalid`, password: randomBytes(18).toString('base64url'), returnSecureToken: true});
  const claims = JSON.parse(Buffer.from(data.idToken.split('.')[1], 'base64url'));
  if (claims.aud !== PROJECT) throw Error('STOP: token is outside Dev');
  return {uid: data.localId, idToken: data.idToken};
}
(async () => {
  const a = await signUp('a'), b = await signUp('b'), results = [];
  const uuid = randomUUID();
  const ctx = day => ({localCourseId: uuid, localCourseUUID: uuid, year: 2026, semester: 'fall', courseName: '架空の授業', teacherName: '架空教員', syllabusUrl: '', dayID: day, occurrenceKey: 'default'});
  const t0 = Date.now() - 60_000, day = 20_000;
  const step = async (name, fn) => { await fn(); results.push(name); console.log('PASS', name); };
  try {
    await step('Webの端末が、質問と返信を保存する', async () => assert.deepEqual(await call('aiSaveMessages', a, {context: ctx(day), messages: [
      {id: 'web-q-' + t0, role: 'user', text: 'Webからの質問', createdAt: t0}, {id: 'web-a-' + t0, role: 'assistant', text: 'Webでの返信', createdAt: t0 + 1000}]}), {saved: 2}));
    await step('アプリの端末が、画像を送った印と質問を保存する(別の授業回も)', async () => {
      await call('aiSaveMessages', a, {context: ctx(day), messages: [{id: 'app-img-' + t0, role: 'user', kind: 'image', text: '', imageCount: 2, createdAt: t0 + 2000}]});
      await call('aiSaveMessages', a, {context: ctx(day + 7), messages: [{id: 'app-q-' + t0, role: 'user', text: '次の回の質問', createdAt: t0 + 3000}]});
    });
    await step('同じアカウントなら、別の端末から、全部が時間順で読める', async () => {
      const r = await call('aiListMessages', a, {context: ctx(day)});
      assert.deepEqual(r.items.map(i => [i.id.split('-').slice(0, 2).join('-'), i.role, i.kind, i.dayID, i.imageCount]),
        [['web-q', 'user', 'text', day, 0], ['web-a', 'assistant', 'text', day, 0], ['app-img', 'user', 'image', day, 2], ['app-q', 'user', 'text', day + 7, 0]]);
      assert.equal(r.nextCursor, null);
    });
    await step('同じ内容を送り直しても、増えない', async () => {
      await call('aiSaveMessages', a, {context: ctx(day), messages: [{id: 'web-q-' + t0, role: 'user', text: 'Webからの質問', createdAt: t0}]});
      assert.equal((await call('aiListMessages', a, {context: ctx(day)})).items.length, 4);
    });
    await step('別のアカウントには、見えない', async () => assert.equal((await call('aiListMessages', b, {context: ctx(day)})).items.length, 0));
    await step('不正な入力は、拒否される', async () => {
      await assert.rejects(call('aiSaveMessages', a, {context: ctx(day), messages: [{id: 'bad', role: 'system', text: 'x', createdAt: t0}]}));
      await assert.rejects(call('aiSaveMessages', a, {context: ctx(day), messages: [{id: 'bad2', role: 'user', text: '', createdAt: t0}]}));
    });
    await step('消した発言は、サーバーからも消える', async () => {
      assert.deepEqual(await call('aiDeleteMessages', a, {context: ctx(day), ids: ['web-a-' + t0]}), {deleted: 1});
      assert.equal((await call('aiListMessages', a, {context: ctx(day)})).items.some(i => i.id === 'web-a-' + t0), false);
    });
  } finally {
    // 後片づけ: 会話を消して、テストアカウントも消す
    for (const user of [a, b]) {
      try {
        const r = await call('aiListMessages', user, {context: ctx(day)});
        const ids = r.items.map(i => i.id); if (ids.length) await call('aiDeleteMessages', user, {context: ctx(day), ids});
      } catch {}
      try { await auth('accounts:delete', {idToken: user.idToken}); } catch {}
    }
  }
  console.log(`\nDev E2E: ${results.length}/7 PASS`);
})().catch(e => { console.error('FAIL', e.message, e.status || ''); process.exit(1); });

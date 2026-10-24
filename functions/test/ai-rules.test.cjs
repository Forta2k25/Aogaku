// AI用データベースのルール(Config/AI/firestore.rules)を、Firestoreエミュレータで確かめる。
// 実行: firebase emulators:exec --only firestore --project demo-ai-rules --config firebase.ai-rules-test.json "node --test functions/test/ai-rules.test.cjs"
const {test} = require('node:test');
const assert = require('node:assert/strict');
const host = process.env.FIRESTORE_EMULATOR_HOST;
const enabled = !!host;
const base = `http://${host}/v1/projects/demo-ai-rules/databases/(default)/documents`;
const jwt = uid => {
  const part = x => Buffer.from(JSON.stringify(x)).toString('base64url');
  return `${part({alg: 'none', typ: 'JWT'})}.${part({user_id: uid, sub: uid, aud: 'demo-ai-rules', firebase: {sign_in_provider: 'password'}})}.`;
};
const req = (method, path, auth, body) => fetch(`${base}/${path}`, {method, headers: {'Content-Type': 'application/json', ...(auth ? {Authorization: `Bearer ${auth}`} : {})}, body: body ? JSON.stringify(body) : undefined});
const seed = (path, fields) => req('PATCH', path, 'owner', {fields});   // 管理者の権限(ルールを通らない)で、準備する
const text = value => ({stringValue: value});
test('会話の履歴: 本人だけが読める。書き込みと、ほかのデータは、読み書きとも拒否', {skip: !enabled}, async () => {
  const mine = 'aiChats/alice/offerings/local:abc/messages/m1';
  assert.equal((await seed(mine, {text: text('こんにちは'), role: text('user')})).status, 200);
  assert.equal((await seed('aiChats/bob/offerings/local:xyz/messages/m9', {text: text('別の人の会話')})).status, 200);
  assert.equal((await seed('aiUsage/alice/periods/day', {count: {integerValue: '1'}})).status, 200);
  assert.equal((await seed('aiSources/s1', {ownerUserId: text('alice')})).status, 200);
  // 本人は、1件も、一覧も、読める
  assert.equal((await req('GET', mine, jwt('alice'))).status, 200);
  assert.equal((await req('GET', 'aiChats/alice/offerings/local:abc/messages', jwt('alice'))).status, 200);
  // 別のアカウント・未ログインは、読めない
  assert.equal((await req('GET', mine, jwt('bob'))).status, 403);
  assert.equal((await req('GET', mine, null)).status, 403);
  assert.equal((await req('GET', 'aiChats/bob/offerings/local:xyz/messages/m9', jwt('alice'))).status, 403, '他人の会話は、読めない');
  // 本人でも、書き込み・更新・削除は、できない
  assert.equal((await req('PATCH', 'aiChats/alice/offerings/local:abc/messages/m2', jwt('alice'), {fields: {text: text('直接書く')}})).status, 403);
  assert.equal((await req('PATCH', mine, jwt('alice'), {fields: {text: text('書き換え')}})).status, 403);
  assert.equal((await req('DELETE', mine, jwt('alice'))).status, 403);
  // 会話以外(利用量・資料)は、本人でも、読めない
  assert.equal((await req('GET', 'aiUsage/alice/periods/day', jwt('alice'))).status, 403);
  assert.equal((await req('GET', 'aiSources/s1', jwt('alice'))).status, 403);
  // 会話の「親」の階層(授業の一覧など)も、読めない(読めるのは、発言の1件1件だけ)
  assert.equal((await req('GET', 'aiChats/alice', jwt('alice'))).status, 403);
});

test('時間割の共有URL: 長いIDなら誰でも1件だけ読める。一覧と、他人の書き換えは拒否', {skip: !enabled}, async () => {
  const id = 'abcdefghijklmnopqrstuvwxyz012345';
  const body = owner => ({fields: {ownerUid: text(owner), ownerName: text('れお')}});
  assert.equal((await req('PATCH', `sharedTimetables/${id}`, jwt('alice'), body('alice'))).status, 200, '本人は作れる');
  assert.equal((await req('GET', `sharedTimetables/${id}`, null)).status, 200, '未ログインでも1件は読める');
  assert.equal((await req('GET', 'sharedTimetables', null)).status, 403, '一覧は読めない');
  assert.equal((await req('PATCH', `sharedTimetables/${id}`, jwt('bob'), body('bob'))).status, 403, '他人は書き換えられない');
  assert.equal((await req('PATCH', 'sharedTimetables/short', jwt('alice'), body('alice'))).status, 403, '短いIDは作れない');
  assert.equal((await req('PATCH', 'sharedTimetables/' + id.replace('a', 'b'), jwt('alice'), body('bob'))).status, 403, '他人名義では作れない');
  assert.equal((await req('DELETE', `sharedTimetables/${id}`, jwt('bob'))).status, 403);
  assert.equal((await req('DELETE', `sharedTimetables/${id}`, jwt('alice'))).status, 200);
});
test('課題の置き場: 本人だけが読み書きできる', {skip: !enabled}, async () => {
  const f = {fields: {submitted: {arrayValue: {values: [text('x')]}}}};
  assert.equal((await req('PATCH', 'userAssignments/alice', jwt('alice'), f)).status, 200);
  assert.equal((await req('GET', 'userAssignments/alice', jwt('alice'))).status, 200);
  assert.equal((await req('GET', 'userAssignments/alice', jwt('bob'))).status, 403);
  assert.equal((await req('GET', 'userAssignments/alice', null)).status, 403);
  assert.equal((await req('PATCH', 'userAssignments/alice', jwt('bob'), f)).status, 403);
});

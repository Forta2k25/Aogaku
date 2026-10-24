#!/usr/bin/env node
// Dev だけ。IDとパスワードでログインできる、架空のテストアカウントを1つ作る(アプリは「ID@aogaku.app」のメールで認証する)。
// ID とパスワードは、画面やチャットには出さず、自分だけが読めるファイル(scripts/output-dev/dev-test-account.json)に保存する。
const {readFileSync, writeFileSync, existsSync, chmodSync, mkdirSync} = require('node:fs');
const {execFileSync} = require('node:child_process');
const {join} = require('node:path');
const {randomBytes, randomInt} = require('node:crypto');
const ROOT = join(__dirname, '..'), PROJECT = 'forta-aogaku-dev';
const manifest = JSON.parse(readFileSync(join(ROOT, 'Config/firebase-development.json')));
if (manifest.projectId !== PROJECT || manifest.projectNumber !== '1064661805206') throw Error('STOP: approved Dev identity mismatch');
const out = join(ROOT, 'scripts/output-dev/dev-test-account.json');
mkdirSync(join(ROOT, 'scripts/output-dev'), {recursive: true, mode: 0o700});
if (existsSync(out)) { console.log(`すでにあります: ${out}`); process.exit(0); }
const key = execFileSync('python3', ['-c', 'import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'], {cwd: ROOT, encoding: 'utf8'}).trim();
(async () => {
  const id = `convtest${randomInt(1000, 9999)}`, password = randomBytes(12).toString('base64url');
  const r = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${encodeURIComponent(key)}`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({email: `${id}@aogaku.app`, password, returnSecureToken: true})});
  const data = await r.json(); if (!r.ok) throw Error(`Dev Auth HTTP ${r.status}: ${data.error?.message}`);
  const claims = JSON.parse(Buffer.from(data.idToken.split('.')[1], 'base64url')); if (claims.aud !== PROJECT) throw Error('STOP: token is outside Dev');
  writeFileSync(out, JSON.stringify({project: PROJECT, id, password, uid: data.localId}, null, 2) + '\n', {mode: 0o600}); chmodSync(out, 0o600);
  console.log(`作りました(Dev): ${out}`);
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });

#!/usr/bin/env node
// 読み取りだけ。会話の同期の3関数(aiSaveMessages / aiListMessages / aiDeleteMessages)が、既存の aiChat と同じ設定で公開されているかを確かめる。
//   node scripts/verify_conversations_functions.cjs forta-aogaku-dev      # Dev
//   node scripts/verify_conversations_functions.cjs forta-aogaku          # 本番(公開したあとの確認。何も変更しない)
// 前提: gcloud でログイン済み。表示するのは設定の値だけで、会話の中身・秘密の値は読まない。
const {execFileSync} = require('node:child_process');
const project = process.argv[2];
if (!['forta-aogaku-dev', 'forta-aogaku'].includes(project)) { console.error('使い方: verify_conversations_functions.cjs forta-aogaku-dev|forta-aogaku'); process.exit(2); }
const REGION = 'asia-northeast1', NEW = ['aiSaveMessages', 'aiListMessages', 'aiDeleteMessages'];
const gcloud = (...args) => JSON.parse(execFileSync('gcloud', [...args, '--project', project, '--format=json'], {encoding: 'utf8'}));
const describe = name => gcloud('functions', 'describe', name, '--region', REGION, '--gen2');
const invokers = name => {
  const policy = gcloud('run', 'services', 'get-iam-policy', name.toLowerCase(), '--region', REGION);
  return (policy.bindings || []).filter(b => b.role === 'roles/run.invoker').flatMap(b => b.members).sort();
};
const shape = f => ({state: f.state, runtime: f.buildConfig?.runtime, serviceAccount: f.serviceConfig?.serviceAccountEmail,
  ingress: f.serviceConfig?.ingressSettings, timeout: f.serviceConfig?.timeoutSeconds, maxInstances: f.serviceConfig?.maxInstanceCount,
  appCheck: f.serviceConfig?.environmentVariables?.AI_INPUT_REQUIRE_APP_CHECK ?? '(未設定)',
  admission: f.serviceConfig?.environmentVariables?.AI_INPUT_ADMISSION_MODE ?? '(未設定)'});
let failed = false;
const reference = describe('aiChat'), want = shape(reference), wantInvokers = invokers('aiChat');
console.log(`基準: aiChat`, JSON.stringify(want), '呼び出せる主体:', JSON.stringify(wantInvokers));
for (const name of NEW) {
  let f; try { f = describe(name); } catch { console.log(`FAIL ${name}: 関数が見つかりません`); failed = true; continue; }
  const got = shape(f), problems = [];
  if (got.state !== 'ACTIVE') problems.push(`state=${got.state}`);
  for (const key of ['runtime', 'serviceAccount', 'ingress', 'admission', 'appCheck']) if (got[key] !== want[key]) problems.push(`${key}: ${got[key]} (aiChat は ${want[key]})`);
  const inv = invokers(name); if (JSON.stringify(inv) !== JSON.stringify(wantInvokers)) problems.push(`呼び出せる主体が aiChat と違います: ${JSON.stringify(inv)}`);
  console.log(problems.length ? `FAIL ${name}: ${problems.join(' / ')}` : `PASS ${name}`);
  failed ||= problems.length > 0;
}
process.exit(failed ? 1 : 0);

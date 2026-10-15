#!/usr/bin/env node
// CLI does not initialize multiple Rulesets yet. Load the real emulator's
// database-specific Rules endpoint, fail closed before running any test.
const {readFileSync}=require('node:fs'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
async function main(){const host=process.env.FIRESTORE_EMULATOR_HOST;assert(/^(127\.0\.0\.1|localhost):\d+$/.test(host),'local Firestore emulator required');const project='demo-aogaku-input';
 for(const [database,path]of [['(default)','Config/Production/baseline.firestore.rules'],['aogaku-ai','Config/AI/firestore.rules']]){
  const r=await fetch(`http://${host}/emulator/v1/projects/${project}/databases/${database}:securityRules`,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({rules:{files:[{name:'security.rules',content:readFileSync(path,'utf8')}]}})});assert.equal(r.status,200);const body=await r.json();assert(!(body.issues||[]).some(x=>x.severity==='ERROR'),JSON.stringify(body));
 }
 assert.equal((await fetch(`http://${host}/v1/projects/${project}/databases/aogaku-ai/documents/aiSources/preflight/entries/owner`)).status,403,'named rules not installed');
 assert.equal((await fetch(`http://${host}/v1/projects/${project}/databases/(default)/documents/classes/preflight`)).status,404,'default public catalog rules changed');
 console.log('PASS: real emulator Rules loaded for both databases; named arbitrary entries denied; default public catalog unchanged');
 const child=spawnSync('npm',['--prefix','functions','run','test:rollout-emulator'],{stdio:'inherit',env:{...process.env,AI_FIRESTORE_DATABASE_ID:'aogaku-ai'}});process.exitCode=child.status??1;
}
main().catch(e=>{console.error(e);process.exitCode=1});
